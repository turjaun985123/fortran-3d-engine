! f3dc_emit_common.f90 -- shared emitter helpers for the native
! Forge3D compiler.  Port of tools/f3dc/emit_common.py (seat B11);
! contract: compiler/DESIGN.md.  Free subroutines/functions only --
! no type-bound procedures.
!
! Python -> Fortran mapping notes:
! * Python values are dyn values (f3dc_dyn).  Dataclass/dict/list/
!   tuple/set inputs of _json_safe map onto dyn dict/list values;
!   dyn has no set kind, so the Python "set -> sorted-by-repr list"
!   branch has no dyn counterpart (reported divergence).
! * NAMED_COLORS / PALETTE_FACES / parse_color live in ir_nodes.py
!   (f3dc_ir, not yet landed); the frozen tables and the parse_color
!   grammar are inlined here and MUST be replaced by f3dc_ir's when
!   it lands (values copied verbatim from ir_nodes.py).
! * Python exceptions (ValueError/TypeError from rgb_str) cannot be
!   raised in Fortran: rgb_str/resolve_color report them through an
!   ierr code (0 ok, 1 = ValueError, 2 = TypeError) and yield "".
! * source_hash needs SHA-256 (Python hashlib): implemented below
!   in pure Fortran (no stdlib equivalent exists).
module f3dc_emit_common
  use, intrinsic :: iso_fortran_env, only: int64, real64
  use f3dc_str, only: fmt_int, fmt_real, to_lower, &
                      str_builder, sb_init, sb_add, sb_text
  use f3dc_dyn
  implicit none
  private

  public :: fmt_num_dyn, fmt_num_real, fmt_num_int
  public :: fmt_vec_dyn, fmt_vec_reals
  public :: json_dumps, js_json, canonical_json
  public :: source_hash, sha256_hex
  public :: header_stamp, header_stamp_digest
  public :: clamp255_real, clamp255_dyn, clamp255_vec_dyn
  public :: html_escape
  public :: resolve_color, rgb_str
  public :: named_color, palette_face, parse_color_str
  public :: NL

  character(len=*), parameter :: NL = achar(10)

  ! NAMED_COLORS from ir_nodes.py (frozen).
  integer, parameter :: N_NAMED = 13
  character(len=7), parameter :: NAMED_KEYS(N_NAMED) = [character(len=7) :: &
    "red", "green", "blue", "yellow", "magenta", "cyan", "orange", &
    "purple", "pink", "white", "black", "gray", "grey"]
  integer, parameter :: NAMED_RGB(3, N_NAMED) = reshape([ &
    220, 60, 60,   60, 220, 60,   60, 100, 240,  240, 220, 50, &
    200, 80, 220,  60, 220, 220,  240, 140, 40,  140, 80, 200, &
    240, 150, 190, 240, 240, 240, 20, 20, 25,    140, 140, 145, &
    140, 140, 145], [3, N_NAMED])
  ! PALETTE_FACES: south, east, north, west, top, bottom.
  integer, parameter :: PALETTE_RGB(3, 6) = reshape([ &
    220, 60, 60,  60, 220, 60,  60, 100, 240, &
    240, 220, 50, 200, 80, 220, 60, 220, 220], [3, 6])

contains

  ! ------------------------------------------------------------------
  ! Number formatting (fmt_num / fmt_vec)
  ! ------------------------------------------------------------------

  !> emit_common.fmt_num for a dyn value (bool/int/real; anything
  !! else falls back to its string form, mirroring str(x)).
  function fmt_num_dyn(v) result(out)
    type(dyn), intent(in) :: v
    character(len=:), allocatable :: out
    select case (v%kind)
    case (DYN_K_BOOL)
      if (v%b) then
        out = "1"
      else
        out = "0"
      end if
    case (DYN_K_INT)
      out = fmt_int(v%i)
    case (DYN_K_REAL)
      out = fmt_num_real(v%r)
    case (DYN_K_STR)
      if (allocated(v%s)) then
        out = v%s
      else
        out = ""
      end if
    case default
      out = ""
    end select
  end function fmt_num_dyn

  function fmt_num_int(x) result(out)
    integer(int64), intent(in) :: x
    character(len=:), allocatable :: out
    out = fmt_int(x)
  end function fmt_num_int

  !> emit_common.fmt_num for a real64, mirroring the Python float
  !! branch exactly: 0 -> "0", nan/inf words, integral values with
  !! abs < 1e16 render as ints, otherwise repr() with trailing
  !! zeros stripped in fixed notation.
  function fmt_num_real(x) result(out)
    real(real64), intent(in) :: x
    character(len=:), allocatable :: out
    character(len=:), allocatable :: t
    integer :: n
    if (x /= x) then
      out = "nan"
      return
    end if
    if (x == 0.0_real64) then
      out = "0"
      return
    end if
    if (.not. (abs(x) <= huge(x))) then
      if (x > 0.0_real64) then
        out = "inf"
      else
        out = "-inf"
      end if
      return
    end if
    if (abs(x) < 1.0e16_real64) then
      if (x == floor(x)) then
        out = fmt_int(int(x, int64))
        return
      end if
    end if
    t = fmt_real(x)
    if (index(t, "e") > 0 .or. index(t, "E") > 0) then
      out = t
      return
    end if
    if (index(t, ".") > 0) then
      n = len(t)
      do while (n > 0)
        if (t(n:n) /= "0") exit
        n = n - 1
      end do
      if (n > 0) then
        if (t(n:n) == ".") n = n - 1
      end if
      t = t(1:n)
    end if
    if (len(t) == 0 .or. t == "-0") then
      out = "0"
    else
      out = t
    end if
  end function fmt_num_real

  !> fmt_vec over a dyn list: space-separated fmt_num.
  function fmt_vec_dyn(v) result(out)
    type(dyn), intent(in) :: v
    character(len=:), allocatable :: out
    type(str_builder) :: sb
    integer :: k
    if (v%kind /= DYN_K_LIST) then
      out = fmt_num_dyn(v)
      return
    end if
    call sb_init(sb)
    do k = 1, dyn_list_len(v)
      if (k > 1) call sb_add(sb, " ")
      call sb_add(sb, fmt_num_dyn(dyn_list_at(v, k)))
    end do
    out = sb_text(sb)
  end function fmt_vec_dyn

  function fmt_vec_reals(a) result(out)
    real(real64), intent(in) :: a(:)
    character(len=:), allocatable :: out
    type(str_builder) :: sb
    integer :: k
    call sb_init(sb)
    do k = 1, size(a)
      if (k > 1) call sb_add(sb, " ")
      call sb_add(sb, fmt_num_real(a(k)))
    end do
    out = sb_text(sb)
  end function fmt_vec_reals

  ! ------------------------------------------------------------------
  ! JSON serialisation -- byte parity with Python json.dumps
  ! ------------------------------------------------------------------

  !> JSON float rendering: Python json uses repr() but spells the
  !! non-finite values NaN / Infinity / -Infinity.
  function json_real(x) result(out)
    real(real64), intent(in) :: x
    character(len=:), allocatable :: out
    if (x /= x) then
      out = "NaN"
    else if (.not. (abs(x) <= huge(x))) then
      if (x > 0.0_real64) then
        out = "Infinity"
      else
        out = "-Infinity"
      end if
    else
      out = fmt_real(x)
    end if
  end function json_real

  !> json.dumps string escaping with ensure_ascii=False: only the
  !! quote, backslash and control chars < 0x20 are escaped; bytes
  !! >= 0x80 (UTF-8) pass through raw, as does 0x7f.
  function json_escape_raw(s) result(out)
    character(len=*), intent(in) :: s
    character(len=:), allocatable :: out
    type(str_builder) :: sb
    integer :: i, b
    call sb_init(sb)
    do i = 1, len(s)
      b = iachar(s(i:i))
      select case (b)
      case (34)
        call sb_add(sb, '\"')
      case (92)
        call sb_add(sb, '\\')
      case (8)
        call sb_add(sb, '\b')
      case (12)
        call sb_add(sb, '\f')
      case (10)
        call sb_add(sb, '\n')
      case (13)
        call sb_add(sb, '\r')
      case (9)
        call sb_add(sb, '\t')
      case (0:7, 11, 14:31)
        call sb_add(sb, uesc(b))
      case default
        call sb_add(sb, s(i:i))
      end select
    end do
    out = sb_text(sb)
  end function json_escape_raw

  function json_quote(s, ensure_ascii) result(out)
    character(len=*), intent(in) :: s
    logical, intent(in) :: ensure_ascii
    character(len=:), allocatable :: out
    if (ensure_ascii) then
      out = '"' // json_escape_ascii(s) // '"'
    else
      out = '"' // json_escape_raw(s) // '"'
    end if
  end function json_quote

  !> json.dumps escaping with ensure_ascii=True and LOWERCASE hex
  !! (Python's \uXXXX escapes use lowercase hex digits).  This is
  !! implemented locally because the landed f3dc_errors.json_escape
  !! formats hex with Z4.4, which yields UPPERCASE digits and so
  !! diverges from Python for every non-ASCII / control escape --
  !! flagged in the port report; f3dc_errors is another seat's file
  !! and is not modified here.
  function json_escape_ascii(s) result(out)
    character(len=*), intent(in) :: s
    character(len=:), allocatable :: out
    type(str_builder) :: sb
    integer :: i, b, cp, nbytes, j
    call sb_init(sb)
    i = 1
    do while (i <= len(s))
      b = iachar(s(i:i))
      if (b < 128) then
        select case (b)
        case (34)
          call sb_add(sb, '\"')
        case (92)
          call sb_add(sb, '\\')
        case (8)
          call sb_add(sb, '\b')
        case (12)
          call sb_add(sb, '\f')
        case (10)
          call sb_add(sb, '\n')
        case (13)
          call sb_add(sb, '\r')
        case (9)
          call sb_add(sb, '\t')
        case (0:7, 11, 14:31, 127)
          call sb_add(sb, uesc(b))
        case default
          call sb_add(sb, s(i:i))
        end select
        i = i + 1
      else
        if (b >= 240) then
          nbytes = 4
          cp = mod(b, 8)
        else if (b >= 224) then
          nbytes = 3
          cp = mod(b, 16)
        else if (b >= 192) then
          nbytes = 2
          cp = mod(b, 32)
        else
          nbytes = 1
          cp = b
        end if
        if (nbytes > 1) then
          do j = 1, nbytes - 1
            if (i + j > len(s)) exit
            cp = cp * 64 + mod(iachar(s(i + j:i + j)), 64)
          end do
        end if
        if (cp <= 65535) then
          call sb_add(sb, uesc(cp))
        else
          call sb_add(sb, uesc(55296 + (cp - 65536) / 1024))
          call sb_add(sb, uesc(56320 + mod(cp - 65536, 1024)))
        end if
        i = i + nbytes
      end if
    end do
    out = sb_text(sb)
  end function json_escape_ascii

  !> "\uXXXX" with lowercase hex.
  function uesc(cp) result(out)
    integer, intent(in) :: cp
    character(len=6) :: out
    character(len=*), parameter :: HEXD = "0123456789abcdef"
    integer :: k, v
    out(1:2) = "\u"
    v = cp
    do k = 6, 3, -1
      out(k:k) = HEXD(mod(v, 16) + 1:mod(v, 16) + 1)
      v = v / 16
    end do
  end function uesc

  !> Byte-wise (UTF-8) key ordering == Python str code-point order.
  pure logical function key_less(a, b)
    character(len=*), intent(in) :: a, b
    integer :: i, n
    n = min(len(a), len(b))
    key_less = .false.
    do i = 1, n
      if (iachar(a(i:i)) /= iachar(b(i:i))) then
        key_less = iachar(a(i:i)) < iachar(b(i:i))
        return
      end if
    end do
    key_less = len(a) < len(b)
  end function key_less

  !> General json.dumps mirror.
  !! indent == 0: compact, separators (",", ":") -- the shape used
  !! by js_json and the canonical form.  indent >= 1: pretty with
  !! that many spaces per level, separators (",", ": "), exactly
  !! json.dumps(obj, indent=indent).  sort_keys mirrors the Python
  !! flag; ensure_ascii mirrors the Python flag.
  recursive subroutine json_dumps(v, sort_keys, ensure_ascii, indent, out)
    type(dyn), intent(in) :: v
    logical, intent(in) :: sort_keys, ensure_ascii
    integer, intent(in) :: indent
    character(len=:), allocatable, intent(out) :: out
    out = ""
    call dump_rec(v, 0, sort_keys, ensure_ascii, indent, out)
  end subroutine json_dumps

  recursive subroutine dump_rec(v, level, sort_keys, ensure_ascii, &
                                indent, out)
    type(dyn), intent(in) :: v
    integer, intent(in) :: level, indent
    logical, intent(in) :: sort_keys, ensure_ascii
    character(len=:), allocatable, intent(inout) :: out
    integer :: k, n
    integer, allocatable :: order(:)
    character(len=:), allocatable :: key
    type(dyn) :: item
    type(str_builder) :: sb

    ! The builder mirrors `out`: seeded from it on entry, flushed
    ! back to it before each recursive child call (the child keeps
    ! appending to `out` itself) and re-seeded on return, and
    ! flushed on every exit of this invocation.
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
      call sb_add(sb, fmt_int(v%i))
    case (DYN_K_REAL)
      call sb_add(sb, json_real(v%r))
    case (DYN_K_STR)
      if (allocated(v%s)) then
        call sb_add(sb, json_quote(v%s, ensure_ascii))
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
      if (indent <= 0) then
        call sb_add(sb, "[")
        do k = 1, n
          if (k > 1) call sb_add(sb, ",")
          item = dyn_list_at(v, k)
          out = sb_text(sb)
          call dump_rec(item, level + 1, sort_keys, ensure_ascii, &
                        indent, out)
          call sb_init(sb)
          if (allocated(out)) call sb_add(sb, out)
        end do
        call sb_add(sb, "]")
      else
        call sb_add(sb, "[" // NL)
        do k = 1, n
          call sb_add(sb, repeat(" ", indent * (level + 1)))
          item = dyn_list_at(v, k)
          out = sb_text(sb)
          call dump_rec(item, level + 1, sort_keys, ensure_ascii, &
                        indent, out)
          call sb_init(sb)
          if (allocated(out)) call sb_add(sb, out)
          if (k < n) call sb_add(sb, ",")
          call sb_add(sb, NL)
        end do
        call sb_add(sb, repeat(" ", indent * level) // "]")
      end if
    case (DYN_K_DICT)
      n = dyn_dict_len(v)
      if (n == 0) then
        call sb_add(sb, "{}")
        out = sb_text(sb)
        return
      end if
      allocate (order(n))
      do k = 1, n
        order(k) = k
      end do
      if (sort_keys) call sort_order(v, order)
      if (indent <= 0) then
        call sb_add(sb, "{")
        do k = 1, n
          if (k > 1) call sb_add(sb, ",")
          key = dyn_dict_key_at(v, order(k))
          call sb_add(sb, json_quote(key, ensure_ascii) // ":")
          item = dyn_dict_value_at(v, order(k))
          out = sb_text(sb)
          call dump_rec(item, level + 1, sort_keys, ensure_ascii, &
                        indent, out)
          call sb_init(sb)
          if (allocated(out)) call sb_add(sb, out)
        end do
        call sb_add(sb, "}")
      else
        call sb_add(sb, "{" // NL)
        do k = 1, n
          call sb_add(sb, repeat(" ", indent * (level + 1)))
          key = dyn_dict_key_at(v, order(k))
          call sb_add(sb, json_quote(key, ensure_ascii) // ": ")
          item = dyn_dict_value_at(v, order(k))
          out = sb_text(sb)
          call dump_rec(item, level + 1, sort_keys, ensure_ascii, &
                        indent, out)
          call sb_init(sb)
          if (allocated(out)) call sb_add(sb, out)
          if (k < n) call sb_add(sb, ",")
          call sb_add(sb, NL)
        end do
        call sb_add(sb, repeat(" ", indent * level) // "}")
      end if
      deallocate (order)
    case default
      call sb_add(sb, "null")
    end select
    out = sb_text(sb)
  end subroutine dump_rec

  !> Insertion sort of dict entry indices by key (stable, matching
  !! Python's sorted()).
  subroutine sort_order(d, order)
    type(dyn), intent(in) :: d
    integer, intent(inout) :: order(:)
    integer :: i, j, tmp
    character(len=:), allocatable :: ki, kj
    do i = 2, size(order)
      tmp = order(i)
      ki = dyn_dict_key_at(d, tmp)
      j = i - 1
      do while (j >= 1)
        kj = dyn_dict_key_at(d, order(j))
        if (.not. key_less(ki, kj)) exit
        order(j + 1) = order(j)
        j = j - 1
      end do
      order(j + 1) = tmp
    end do
  end subroutine sort_order

  !> emit_common.js_json: compact, ensure_ascii=False, key order
  !! preserved (insertion order).
  subroutine js_json(obj, out)
    type(dyn), intent(in) :: obj
    character(len=:), allocatable, intent(out) :: out
    call json_dumps(obj, .false., .false., 0, out)
  end subroutine js_json

  !> The canonical JSON of source_hash: sorted keys, compact
  !! separators, ensure_ascii=False (emit_common._canonical_json).
  subroutine canonical_json(obj, out)
    type(dyn), intent(in) :: obj
    character(len=:), allocatable, intent(out) :: out
    call json_dumps(obj, .true., .false., 0, out)
  end subroutine canonical_json

  ! ------------------------------------------------------------------
  ! SHA-256 (Python hashlib.sha256) -- pure Fortran implementation
  ! ------------------------------------------------------------------

  pure integer(int64) function rotr32(x, n)
    integer(int64), intent(in) :: x, n
    rotr32 = ior(ishft(x, -int(n)), &
                 ishft(iand(x, int(z'FFFFFFFF', int64)), &
                       int(32 - n)))
    rotr32 = iand(rotr32, int(z'FFFFFFFF', int64))
  end function rotr32

  !> sha256 hex digest (lowercase) of the bytes of `bytes`.
  subroutine sha256_hex(bytes, out)
    character(len=*), intent(in) :: bytes
    character(len=:), allocatable, intent(out) :: out
    integer(int64), parameter :: MASK = int(z'FFFFFFFF', int64)
    integer(int64), parameter :: K(64) = [ &
      int(z'428a2f98', int64), int(z'71374491', int64), &
      int(z'b5c0fbcf', int64), int(z'e9b5dba5', int64), &
      int(z'3956c25b', int64), int(z'59f111f1', int64), &
      int(z'923f82a4', int64), int(z'ab1c5ed5', int64), &
      int(z'd807aa98', int64), int(z'12835b01', int64), &
      int(z'243185be', int64), int(z'550c7dc3', int64), &
      int(z'72be5d74', int64), int(z'80deb1fe', int64), &
      int(z'9bdc06a7', int64), int(z'c19bf174', int64), &
      int(z'e49b69c1', int64), int(z'efbe4786', int64), &
      int(z'0fc19dc6', int64), int(z'240ca1cc', int64), &
      int(z'2de92c6f', int64), int(z'4a7484aa', int64), &
      int(z'5cb0a9dc', int64), int(z'76f988da', int64), &
      int(z'983e5152', int64), int(z'a831c66d', int64), &
      int(z'b00327c8', int64), int(z'bf597fc7', int64), &
      int(z'c6e00bf3', int64), int(z'd5a79147', int64), &
      int(z'06ca6351', int64), int(z'14292967', int64), &
      int(z'27b70a85', int64), int(z'2e1b2138', int64), &
      int(z'4d2c6dfc', int64), int(z'53380d13', int64), &
      int(z'650a7354', int64), int(z'766a0abb', int64), &
      int(z'81c2c92e', int64), int(z'92722c85', int64), &
      int(z'a2bfe8a1', int64), int(z'a81a664b', int64), &
      int(z'c24b8b70', int64), int(z'c76c51a3', int64), &
      int(z'd192e819', int64), int(z'd6990624', int64), &
      int(z'f40e3585', int64), int(z'106aa070', int64), &
      int(z'19a4c116', int64), int(z'1e376c08', int64), &
      int(z'2748774c', int64), int(z'34b0bcb5', int64), &
      int(z'391c0cb3', int64), int(z'4ed8aa4a', int64), &
      int(z'5b9cca4f', int64), int(z'682e6ff3', int64), &
      int(z'748f82ee', int64), int(z'78a5636f', int64), &
      int(z'84c87814', int64), int(z'8cc70208', int64), &
      int(z'90befffa', int64), int(z'a4506ceb', int64), &
      int(z'bef9a3f7', int64), int(z'c67178f2', int64)]
    integer(int64) :: h(8), w(64), a, b, c, d, e, f, g, hh
    integer(int64) :: s0, s1, ch, maj, t1, t2, bitlen
    integer :: total, blk, nblk, i, t, off, byte
    character(len=1) :: msg_byte
    type(str_builder) :: sb

    h = [int(z'6a09e667', int64), int(z'bb67ae85', int64), &
         int(z'3c6ef372', int64), int(z'a54ff53a', int64), &
         int(z'510e527f', int64), int(z'9b05688c', int64), &
         int(z'1f83d9ab', int64), int(z'5be0cd19', int64)]
    bitlen = int(len(bytes), int64) * 8_int64
    total = ((len(bytes) + 9 + 63) / 64) * 64
    nblk = total / 64
    do blk = 0, nblk - 1
      do t = 0, 63
        if (t < 16) then
          w(t + 1) = 0_int64
          do i = 0, 3
            off = blk * 64 + t * 4 + i
            byte = padded_byte(bytes, off, bitlen)
            w(t + 1) = ior(ishft(w(t + 1), 8), int(byte, int64))
          end do
        else
          s0 = ieor(ieor(rotr32(w(t - 14), 7_int64), &
                         rotr32(w(t - 14), 18_int64)), &
                    ishft(w(t - 14), -3))
          s1 = ieor(ieor(rotr32(w(t - 1), 17_int64), &
                         rotr32(w(t - 1), 19_int64)), &
                    ishft(w(t - 1), -10))
          w(t + 1) = iand(w(t - 15) + s0 + w(t - 6) + s1, MASK)
        end if
      end do
      a = h(1); b = h(2); c = h(3); d = h(4)
      e = h(5); f = h(6); g = h(7); hh = h(8)
      do t = 0, 63
        s1 = ieor(ieor(rotr32(e, 6_int64), rotr32(e, 11_int64)), &
                  rotr32(e, 25_int64))
        ch = ieor(iand(e, f), iand(not(e), g))
        ch = iand(ch, MASK)
        t1 = iand(hh + s1 + ch + K(t + 1) + w(t + 1), MASK)
        s0 = ieor(ieor(rotr32(a, 2_int64), rotr32(a, 13_int64)), &
                  rotr32(a, 22_int64))
        maj = ieor(ieor(iand(a, b), iand(a, c)), iand(b, c))
        maj = iand(maj, MASK)
        t2 = iand(s0 + maj, MASK)
        hh = g; g = f; f = e
        e = iand(d + t1, MASK)
        d = c; c = b; b = a
        a = iand(t1 + t2, MASK)
      end do
      h(1) = iand(h(1) + a, MASK); h(2) = iand(h(2) + b, MASK)
      h(3) = iand(h(3) + c, MASK); h(4) = iand(h(4) + d, MASK)
      h(5) = iand(h(5) + e, MASK); h(6) = iand(h(6) + f, MASK)
      h(7) = iand(h(7) + g, MASK); h(8) = iand(h(8) + hh, MASK)
    end do
    call sb_init(sb)
    do i = 1, 8
      call sb_add(sb, hex8(h(i)))
    end do
    out = sb_text(sb)
    msg_byte = " "  ! silence unused warnings on some compilers
  end subroutine sha256_hex

  !> Byte `off` (0-based) of the padded SHA-256 message.
  pure integer function padded_byte(bytes, off, bitlen)
    character(len=*), intent(in) :: bytes
    integer, intent(in) :: off
    integer(int64), intent(in) :: bitlen
    integer :: n
    n = len(bytes)
    if (off < n) then
      padded_byte = iachar(bytes(off + 1:off + 1))
    else if (off == n) then
      padded_byte = 128
    else if (off >= ((n + 9 + 63) / 64) * 64 - 8) then
      block
        integer :: sh
        sh = (((n + 9 + 63) / 64) * 64 - 1 - off) * 8
        padded_byte = int(iand(ishft(bitlen, -sh), 255_int64))
      end block
    else
      padded_byte = 0
    end if
  end function padded_byte

  function hex8(x) result(out)
    integer(int64), intent(in) :: x
    character(len=8) :: out
    character(len=*), parameter :: HEXD = "0123456789abcdef"
    integer :: i, nib
    do i = 1, 8
      nib = int(iand(ishft(x, -(8 - i) * 4), 15_int64))
      out(i:i) = HEXD(nib + 1:nib + 1)
    end do
  end function hex8

  !> emit_common.source_hash: sha256 of the canonical JSON.
  subroutine source_hash(obj, out)
    type(dyn), intent(in) :: obj
    character(len=:), allocatable, intent(out) :: out
    character(len=:), allocatable :: canon
    call canonical_json(obj, canon)
    call sha256_hex(canon, out)
  end subroutine source_hash

  ! ------------------------------------------------------------------
  ! Header stamp
  ! ------------------------------------------------------------------

  pure logical function is_hex64(s)
    character(len=*), intent(in) :: s
    integer :: i, b
    is_hex64 = .false.
    if (len(s) /= 64) return
    do i = 1, 64
      b = iachar(s(i:i))
      if (.not. ((b >= 48 .and. b <= 57) .or. &
                  (b >= 65 .and. b <= 70) .or. &
                  (b >= 97 .and. b <= 102))) return
    end do
    is_hex64 = .true.
  end function is_hex64

  !> emit_common.header_stamp(source_name, obj, comment): three
  !! lines joined by "\n", no trailing newline.  `obj` may be
  !! absent (Python default None -> hash of "null"), a dyn string
  !! holding a 64-char hex digest (used verbatim, lowercased), or
  !! any dyn value (hashed via source_hash).
  subroutine header_stamp(source_name, out, obj, comment)
    character(len=*), intent(in) :: source_name
    character(len=:), allocatable, intent(out) :: out
    type(dyn), intent(in), optional :: obj
    character(len=*), intent(in), optional :: comment
    character(len=:), allocatable :: digest, prefix
    type(dyn) :: null_obj
    if (present(comment)) then
      prefix = comment
    else
      prefix = "#"
    end if
    if (present(obj)) then
      if (obj%kind == DYN_K_STR .and. allocated(obj%s)) then
        if (is_hex64(obj%s)) then
          digest = to_lower(obj%s)
        else
          call source_hash(obj, digest)
        end if
      else
        call source_hash(obj, digest)
      end if
    else
      null_obj = dyn_null()
      call source_hash(null_obj, digest)
    end if
    out = prefix // " Forge3D generated file - do not edit" // NL // &
          prefix // " source: " // source_name // NL // &
          prefix // " sha256: " // digest
  end subroutine header_stamp

  !> header_stamp with an already-computed digest string.
  subroutine header_stamp_digest(source_name, digest_in, comment, out)
    character(len=*), intent(in) :: source_name, digest_in, comment
    character(len=:), allocatable, intent(out) :: out
    out = comment // " Forge3D generated file - do not edit" // NL // &
          comment // " source: " // source_name // NL // &
          comment // " sha256: " // to_lower(digest_in)
  end subroutine header_stamp_digest

  ! ------------------------------------------------------------------
  ! Colours
  ! ------------------------------------------------------------------

  !> Python round() (banker's rounding) for the clamp255 range.
  pure integer function py_round(x) result(r)
    real(real64), intent(in) :: x
    real(real64) :: fl, frac
    integer(int64) :: base
    fl = floor(x)
    base = int(fl, int64)
    frac = x - fl
    if (frac > 0.5_real64) then
      r = int(base + 1_int64)
    else if (frac < 0.5_real64) then
      r = int(base)
    else if (mod(base, 2_int64) == 0_int64) then
      r = int(base)
    else
      r = int(base + 1_int64)
    end if
  end function py_round

  !> emit_common.clamp255 for one real channel.
  pure integer function clamp255_real(v) result(out)
    real(real64), intent(in) :: v
    if (v /= v) then
      out = 0
    else if (v <= 0.0_real64) then
      out = 0
    else if (v >= 255.0_real64) then
      out = 255
    else
      out = py_round(v)
    end if
  end function clamp255_real

  !> clamp255 for a dyn channel: float(v) semantics -- bool counts
  !! as 0/1, a non-numeric string yields 0 (Python TypeError/
  !! ValueError branch), containers yield 0.
  integer function clamp255_dyn(v) result(out)
    type(dyn), intent(in) :: v
    real(real64) :: x
    integer :: ios
    select case (v%kind)
    case (DYN_K_BOOL)
      if (v%b) then
        out = 1
      else
        out = 0
      end if
    case (DYN_K_INT)
      out = clamp255_real(real(v%i, real64))
    case (DYN_K_REAL)
      out = clamp255_real(v%r)
    case (DYN_K_STR)
      if (allocated(v%s)) then
        read (v%s, *, iostat=ios) x
        if (ios /= 0) then
          out = 0
        else
          out = clamp255_real(x)
        end if
      else
        out = 0
      end if
    case default
      out = 0
    end select
  end function clamp255_dyn

  !> clamp255 element-wise over a dyn list (Python tuple branch).
  subroutine clamp255_vec_dyn(v, out)
    type(dyn), intent(in) :: v
    integer, allocatable, intent(out) :: out(:)
    integer :: k, n
    n = dyn_list_len(v)
    allocate (out(n))
    do k = 1, n
      out(k) = clamp255_dyn(dyn_list_at(v, k))
    end do
  end subroutine clamp255_vec_dyn

  !> NAMED_COLORS lookup (already-lowercased key expected).
  subroutine named_color(key_lower, rgb, found)
    character(len=*), intent(in) :: key_lower
    integer, intent(out) :: rgb(3)
    logical, intent(out) :: found
    integer :: k
    found = .false.
    rgb = 0
    do k = 1, N_NAMED
      if (trim(NAMED_KEYS(k)) == key_lower) then
        rgb = NAMED_RGB(:, k)
        found = .true.
        return
      end if
    end do
  end subroutine named_color

  !> PALETTE_FACES entry for a 0-based index.
  subroutine palette_face(idx0, rgb, found)
    integer, intent(in) :: idx0
    integer, intent(out) :: rgb(3)
    logical, intent(out) :: found
    if (idx0 >= 0 .and. idx0 < 6) then
      rgb = PALETTE_RGB(:, idx0 + 1)
      found = .true.
    else
      rgb = 0
      found = .false.
    end if
  end subroutine palette_face

  !> Strip ASCII whitespace from both ends (Python str.strip()).
  function strip_ws(s) result(out)
    character(len=*), intent(in) :: s
    character(len=:), allocatable :: out
    integer :: a, b, c
    a = 1
    b = len(s)
    do while (a <= b)
      c = iachar(s(a:a))
      if (c == 32 .or. (c >= 9 .and. c <= 13)) then
        a = a + 1
      else
        exit
      end if
    end do
    do while (b >= a)
      c = iachar(s(b:b))
      if (c == 32 .or. (c >= 9 .and. c <= 13)) then
        b = b - 1
      else
        exit
      end if
    end do
    if (b < a) then
      out = ""
    else
      out = s(a:b)
    end if
  end function strip_ws

  !> ir_nodes.parse_color for a string: named / #rrggbb /
  !! rgb(r,g,b) with the frozen regex grammar; ok=.false. mirrors
  !! a None return (unknown or out-of-range).
  subroutine parse_color_str(raw, rgb, ok)
    character(len=*), intent(in) :: raw
    integer, intent(out) :: rgb(3)
    logical, intent(out) :: ok
    character(len=:), allocatable :: text, low
    integer :: i, vals(3), ndig, v, pos, n
    logical :: is_sp
    ok = .false.
    rgb = 0
    text = strip_ws(raw)
    low = to_lower(text)
    call named_color(low, rgb, ok)
    if (ok) return
    ! #rrggbb
    if (len(text) == 7) then
     if (text(1:1) == "#") then
      ok = .true.
      do i = 1, 3
        v = hex2(text(2 * i:2 * i + 1))
        if (v < 0) ok = .false.
        rgb(i) = max(v, 0)
      end do
      if (.not. ok) rgb = 0
      return
     end if
    end if
    ! rgb(r,g,b), case-insensitive, \s* around numbers and commas
    n = len(text)
    if (n >= 4) then
      if (to_lower(text(1:4)) == "rgb(" .and. text(n:n) == ")") then
        pos = 5
        ok = .true.
        do i = 1, 3
          call skip_ws(text, pos)
          v = 0
          ndig = 0
          do while (pos <= n - 1)
            if (text(pos:pos) >= "0" .and. text(pos:pos) <= "9") then
              v = v * 10 + iachar(text(pos:pos)) - 48
              ndig = ndig + 1
              pos = pos + 1
            else
              exit
            end if
          end do
          if (ndig < 1 .or. ndig > 3) ok = .false.
          vals(i) = v
          call skip_ws(text, pos)
          if (i < 3) then
            if (pos > n - 1) then
              ok = .false.
            else if (text(pos:pos) /= ",") then
              ok = .false.
            end if
            pos = pos + 1
          end if
        end do
        if (pos /= n) ok = .false.
        if (ok) then
          if (any(vals < 0) .or. any(vals > 255)) then
            ok = .false.
          else
            rgb = vals
          end if
        end if
        if (.not. ok) rgb = 0
        return
      end if
    end if
    is_sp = .false.  ! (kept for parity with the regex structure)
    if (is_sp) ok = .true.
  end subroutine parse_color_str

  subroutine skip_ws(s, pos)
    character(len=*), intent(in) :: s
    integer, intent(inout) :: pos
    integer :: c
    do while (pos <= len(s))
      c = iachar(s(pos:pos))
      if (c == 32 .or. (c >= 9 .and. c <= 13)) then
        pos = pos + 1
      else
        exit
      end if
    end do
  end subroutine skip_ws

  pure integer function hex2(s) result(v)
    character(len=2), intent(in) :: s
    integer :: i, d
    v = 0
    do i = 1, 2
      if (s(i:i) >= "0" .and. s(i:i) <= "9") then
        d = iachar(s(i:i)) - 48
      else if (s(i:i) >= "a" .and. s(i:i) <= "f") then
        d = iachar(s(i:i)) - 87
      else if (s(i:i) >= "A" .and. s(i:i) <= "F") then
        d = iachar(s(i:i)) - 55
      else
        v = -1
        return
      end if
      v = v * 16 + d
    end do
  end function hex2

  !> emit_common._resolve_color: resolve a dyn colour spec to
  !! three channels kept as dyn values (so clamp255 sees the exact
  !! Python values).  ierr: 0 ok, 1 ValueError, 2 TypeError.
  subroutine resolve_color(color, chans, ierr)
    type(dyn), intent(in) :: color
    type(dyn), intent(out) :: chans(3)
    integer, intent(out) :: ierr
    integer :: rgb(3), k
    logical :: ok
    character(len=:), allocatable :: key
    ierr = 0
    select case (color%kind)
    case (DYN_K_NULL)
      ierr = 1  ! rgb_str(None) -> ValueError via the None check
    case (DYN_K_LIST)
      if (dyn_list_len(color) /= 3) then
        ierr = 1
        return
      end if
      do k = 1, 3
        chans(k) = dyn_list_at(color, k)
      end do
    case (DYN_K_STR)
      if (.not. allocated(color%s)) then
        ierr = 1
        return
      end if
      key = to_lower(strip_ws(color%s))
      call named_color(key, rgb, ok)
      if (.not. ok) call parse_color_str(color%s, rgb, ok)
      if (.not. ok) then
        ierr = 1
        return
      end if
      do k = 1, 3
        chans(k) = dyn_int(int(rgb(k), int64))
      end do
    case (DYN_K_INT)
      call palette_face(int(color%i), rgb, ok)
      if (.not. ok) then
        ierr = 1
        return
      end if
      do k = 1, 3
        chans(k) = dyn_int(int(rgb(k), int64))
      end do
    case default
      ierr = 2
    end select
  end subroutine resolve_color

  !> emit_common.rgb_str: 'r g b' with channels clamped 0..255.
  subroutine rgb_str(color, out, ierr)
    type(dyn), intent(in) :: color
    character(len=:), allocatable, intent(out) :: out
    integer, intent(out) :: ierr
    type(dyn) :: chans(3)
    integer :: k, vals(3)
    call resolve_color(color, chans, ierr)
    if (ierr /= 0) then
      out = ""
      return
    end if
    do k = 1, 3
      vals(k) = clamp255_dyn(chans(k))
    end do
    out = trim(fmt_int(int(vals(1), int64))) // " " // &
          trim(fmt_int(int(vals(2), int64))) // " " // &
          trim(fmt_int(int(vals(3), int64)))
  end subroutine rgb_str

  ! ------------------------------------------------------------------
  ! Escaping
  ! ------------------------------------------------------------------

  !> emit_common.html_escape: html.escape(s, quote=True) --
  !! & first, then < > and both quote characters.
  function html_escape(s) result(out)
    character(len=*), intent(in) :: s
    character(len=:), allocatable :: out
    type(str_builder) :: sb
    integer :: i
    call sb_init(sb)
    do i = 1, len(s)
      select case (s(i:i))
      case ("&")
        call sb_add(sb, "&amp;")
      case ("<")
        call sb_add(sb, "&lt;")
      case (">")
        call sb_add(sb, "&gt;")
      case ('"')
        call sb_add(sb, "&quot;")
      case ("'")
        call sb_add(sb, "&#x27;")
      case default
        call sb_add(sb, s(i:i))
      end select
    end do
    out = sb_text(sb)
  end function html_escape

end module f3dc_emit_common
