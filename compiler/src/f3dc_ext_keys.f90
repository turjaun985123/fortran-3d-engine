! f3dc_ext_keys.f90 -- keyframe tracks extension for the native
! Forge3D compiler.  Port of tools/f3dc/ext_keys.py (read in full,
! 360 lines), per compiler/DESIGN.md.  Python is the oracle.
!
! Public API (exact Python names, dyn representation):
!   build_tracks(headers, keys, tracks)
!       headers: dyn dict  target -> {"duration": dyn, "loop": dyn,
!                "fps": dyn (optional, v3.0 Phase 5)}
!       v3.0 Phase 5 (additive): a header may carry "fps"; when it
!       does, the built track dict carries "fps" too and
!       track_lines appends " fps <fps>" to the .scene 'keys' line
!       (the v1 reader parses that optional 6th/7th token pair;
!       key times/duration are then FRAME NUMBERS, see
!       keyframe_3d).  Headers without "fps" produce byte-identical
!       track dicts and .scene lines to the pre-Phase-5 compiler.
!       validate_tracks also accepts the Phase 5 ease names
!       cubic-in / cubic-out / cubic-in-out (ease_value in
!       animation_3d); 'bezier(...)' cannot be written in the .f3d
!       key grammar (the parser reads a bare ease identifier), so
!       it is not accepted here.
!       keys:    dyn list of raw key dicts
!       tracks:  dyn dict out, {target: {"duration": real, "loop":
!                str, "keys": [normalised key dicts sorted by time]}}
!                Normalised key dict keys, in Python insertion order:
!                target, time, pos, rot, scale, ease; pos/rot are
!                dyn lists of 3 dyn_real, time/scale dyn_real.
!   validate_tracks(tracks, errors)
!       errors: char_list out (appended), the Python list[str].
!   track_lines(target, track, lines)
!       lines: char_list out (appended), the .scene lines.
!
! No type-bound procedures.  Float spelling in .scene lines and in
! diagnostic _fmt() slots is Python "%.6g" (fmt_g6 below), NOT
! f3dc_str's fmt_real (which is Python repr); repr is used only for
! %r slots in diagnostics, via fmt_real, exactly as Python does.
module f3dc_ext_keys
  use, intrinsic :: iso_fortran_env, only: int64, real64
  use, intrinsic :: ieee_arithmetic, only: ieee_is_finite, &
       ieee_is_nan, ieee_is_negative, ieee_value, ieee_quiet_nan, &
       ieee_positive_inf
  use f3dc_dyn, only: dyn, dyn_null, dyn_bool, dyn_int, dyn_real, &
       dyn_str, dyn_list, dyn_dict, dyn_copy, dyn_assign, dyn_list_push, &
       dyn_list_len, dyn_list_at, dyn_dict_get, dyn_dict_set, &
       dyn_dict_has, dyn_dict_len, dyn_dict_key_at, dyn_dict_value_at, &
       DYN_K_NULL, DYN_K_BOOL, DYN_K_INT, DYN_K_REAL, DYN_K_STR, &
       DYN_K_LIST, DYN_K_DICT
  use f3dc_str, only: char_list, char_list_append, char_list_len, &
       fmt_int, fmt_real, to_lower
  implicit none
  private

  public :: build_tracks, validate_tracks, track_lines

  character(len=*), parameter :: DEFAULT_LOOP = "once"
  character(len=*), parameter :: DEFAULT_EASE = "linear"
  real(real64), parameter :: DEF_POS(3) = [0.0_real64, 0.0_real64, &
                                           0.0_real64]
  real(real64), parameter :: DEF_ROT(3) = [0.0_real64, 0.0_real64, &
                                           0.0_real64]

contains

  ! =================================================================
  ! Small Python-semantics helpers
  ! =================================================================

  !> Value of dict key; dyn_null when absent / not a dict.
  function dget(d, key) result(v)
    type(dyn), intent(in) :: d
    character(len=*), intent(in) :: key
    type(dyn) :: v
    v = dyn_dict_get(d, key)
  end function dget

  !> String payload of a dyn_str ("" when unallocated).
  function s_of(v) result(out)
    type(dyn), intent(in) :: v
    character(len=:), allocatable :: out
    if (v%kind == DYN_K_STR .and. allocated(v%s)) then
      out = v%s
    else
      out = ""
    end if
  end function s_of

  pure logical function is_ws(c)
    character, intent(in) :: c
    integer :: k
    k = iachar(c)
    is_ws = (k == 32 .or. k == 9 .or. k == 10 .or. k == 13 .or. &
             k == 11 .or. k == 12)
  end function is_ws

  !> Python str.strip() (whitespace at both ends).
  function strip_ws(s) result(out)
    character(len=*), intent(in) :: s
    character(len=:), allocatable :: out
    integer :: a, b
    a = 1
    b = len(s)
    do while (a <= b)
      if (.not. is_ws(s(a:a))) exit
      a = a + 1
    end do
    do while (b >= a)
      if (.not. is_ws(s(b:b))) exit
      b = b - 1
    end do
    if (a > b) then
      out = ""
    else
      out = s(a:b)
    end if
  end function strip_ws

  !> Python float(str): value + success.  Handles surrounding
  !! whitespace, inf / infinity / nan spellings and digit
  !! underscores (placement checked only loosely).
  subroutine parse_py_float(s, x, ok)
    character(len=*), intent(in) :: s
    real(real64), intent(out) :: x
    logical, intent(out) :: ok
    character(len=:), allocatable :: t, u, w
    integer :: i, ios
    ok = .false.
    x = 0.0_real64
    t = strip_ws(s)
    u = to_lower(t)
    if (u == "inf" .or. u == "+inf" .or. u == "infinity" .or. &
        u == "+infinity") then
      x = ieee_value(0.0_real64, ieee_positive_inf)
      ok = .true.
      return
    end if
    if (u == "-inf" .or. u == "-infinity") then
      x = -ieee_value(0.0_real64, ieee_positive_inf)
      ok = .true.
      return
    end if
    if (u == "nan" .or. u == "+nan" .or. u == "-nan") then
      x = ieee_value(0.0_real64, ieee_quiet_nan)
      ok = .true.
      return
    end if
    ! Drop underscores and reject any character float() would not
    ! accept in a decimal literal.
    w = ""
    do i = 1, len(t)
      if (t(i:i) == "_") cycle
      if (index("0123456789.eE+-", t(i:i)) == 0) return
      w = w // t(i:i)
    end do
    if (len(w) == 0) return
    read (w, *, iostat=ios) x
    if (ios /= 0) then
      x = 0.0_real64
      return
    end if
    ok = .true.
  end subroutine parse_py_float

  !> ext_keys._num(value, default): float or default.  Bools give
  !! the default; non-finite floats are KEPT (validate reports them).
  function num_default(v, def) result(x)
    type(dyn), intent(in) :: v
    real(real64), intent(in) :: def
    real(real64) :: x
    logical :: ok
    select case (v%kind)
    case (DYN_K_INT)
      x = real(v%i, real64)
    case (DYN_K_REAL)
      x = v%r
    case (DYN_K_STR)
      call parse_py_float(s_of(v), x, ok)
      if (.not. ok) x = def
    case default
      x = def
    end select
  end function num_default

  !> ext_keys._num(value, None): has=.false. mirrors a None result.
  subroutine num_none(v, x, has)
    type(dyn), intent(in) :: v
    real(real64), intent(out) :: x
    logical, intent(out) :: has
    x = 0.0_real64
    has = .false.
    select case (v%kind)
    case (DYN_K_INT)
      x = real(v%i, real64)
      has = .true.
    case (DYN_K_REAL)
      x = v%r
      has = .true.
    case (DYN_K_STR)
      call parse_py_float(s_of(v), x, has)
      if (.not. has) x = 0.0_real64
    end select
  end subroutine num_none

  !> Split a vec string on commas / whitespace runs.
  subroutine split_ws_commas(s, parts)
    character(len=*), intent(in) :: s
    type(char_list), intent(out) :: parts
    character(len=:), allocatable :: t
    integer :: i, a
    t = s
    do i = 1, len(t)
      if (t(i:i) == ",") t(i:i) = " "
    end do
    parts = char_list()
    i = 1
    do while (i <= len(t))
      do while (i <= len(t))
        if (.not. is_ws(t(i:i))) exit
        i = i + 1
      end do
      if (i > len(t)) exit
      a = i
      do while (i <= len(t))
        if (is_ws(t(i:i))) exit
        i = i + 1
      end do
      call char_list_append(parts, t(a:i - 1))
    end do
  end subroutine split_ws_commas

  !> Element access on a char_list ("" out of range).
  function cl_at(parts, idx) result(out)
    type(char_list), intent(in) :: parts
    integer, intent(in) :: idx
    character(len=:), allocatable :: out
    if (idx < 1 .or. idx > parts%n) then
      out = ""
    else if (allocated(parts%items(idx)%s)) then
      out = parts%items(idx)%s
    else
      out = ""
    end if
  end function cl_at

  !> ext_keys._vec3(value, default).
  subroutine vec3_default(v, def, out)
    type(dyn), intent(in) :: v
    real(real64), intent(in) :: def(3)
    real(real64), intent(out) :: out(3)
    type(char_list) :: parts
    type(dyn) :: comp
    real(real64) :: x
    logical :: has
    integer :: i
    out = def
    select case (v%kind)
    case (DYN_K_STR)
      call split_ws_commas(s_of(v), parts)
      if (parts%n /= 3) return
      do i = 1, 3
        call parse_py_float(cl_at(parts, i), x, has)
        if (.not. has) then
          out = def
          return
        end if
        out(i) = x
      end do
    case (DYN_K_LIST)
      if (dyn_list_len(v) /= 3) return
      do i = 1, 3
        comp = dyn_list_at(v, i)
        call num_none(comp, x, has)
        if (.not. has) then
          out = def
          return
        end if
        out(i) = x
      end do
    case default
      out = def
    end select
  end subroutine vec3_default

  !> ext_keys._word(value, default): str(value).strip().lower(),
  !! empty -> default; None -> default.
  function word_default(v, def) result(out)
    type(dyn), intent(in) :: v
    character(len=*), intent(in) :: def
    character(len=:), allocatable :: out, t
    select case (v%kind)
    case (DYN_K_STR)
      t = strip_ws(s_of(v))
    case (DYN_K_INT)
      t = fmt_int(v%i)
    case (DYN_K_REAL)
      t = fmt_real(v%r)
    case (DYN_K_BOOL)
      if (v%b) then
        t = "True"
      else
        t = "False"
      end if
    case default
      out = def
      return
    end select
    t = to_lower(t)
    if (len(t) == 0) then
      out = def
    else
      out = t
    end if
  end function word_default

  !> Python str(value) for a target name in _normalise_key:
  !! str(raw.get("target") or "") -- falsy values give "".
  function target_str(v) result(out)
    type(dyn), intent(in) :: v
    character(len=:), allocatable :: out
    select case (v%kind)
    case (DYN_K_STR)
      out = strip_ws(s_of(v))
    case (DYN_K_INT)
      if (v%i == 0_int64) then
        out = ""
      else
        out = strip_ws(fmt_int(v%i))
      end if
    case (DYN_K_REAL)
      if (v%r == 0.0_real64) then
        out = ""
      else
        out = strip_ws(fmt_real(v%r))
      end if
    case (DYN_K_BOOL)
      if (v%b) then
        out = "True"
      else
        out = ""
      end if
    case default
      out = ""
    end select
  end function target_str

  ! -----------------------------------------------------------------
  ! Python "%.6g" % float(x)  (the .scene float spelling, _fmt)
  ! -----------------------------------------------------------------
  function fmt_g6(x) result(out)
    real(real64), intent(in) :: x
    character(len=:), allocatable :: out
    character(len=32) :: buf
    character(len=6) :: digits
    character(len=:), allocatable :: dig, mant, esign, enum
    integer :: epos, exp10, i, nd, ip_end
    real(real64) :: ax
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
    ax = abs(x)
    if (ax == 0.0_real64) then
      if (ieee_is_negative(x)) then
        out = "-0"
      else
        out = "0"
      end if
      return
    end if
    ! 6 significant digits, mantissa d.ddddd, exponent e+XXX.
    write (buf, "(ES14.5E3)") ax
    epos = index(buf, "E")
    digits = buf(3:3) // buf(5:9)   ! 1 + 5 digits, point removed
    read (buf(epos + 1:), *) exp10
    dig = digits
    nd = 6
    do while (nd > 1 .and. dig(nd:nd) == "0")
      nd = nd - 1
    end do
    dig = dig(1:nd)
    if (exp10 >= -4 .and. exp10 < 6) then
      if (exp10 >= 0) then
        ip_end = exp10 + 1
        if (nd > ip_end) then
          out = dig(1:ip_end) // "." // dig(ip_end + 1:nd)
        else
          out = dig
          do i = nd + 1, ip_end
            out = out // "0"
          end do
        end if
      else
        out = "0."
        do i = 1, -exp10 - 1
          out = out // "0"
        end do
        out = out // dig
      end if
    else
      if (nd > 1) then
        mant = dig(1:1) // "." // dig(2:nd)
      else
        mant = dig
      end if
      if (exp10 < 0) then
        esign = "-"
      else
        esign = "+"
      end if
      enum = fmt_int(int(abs(exp10), int64))
      if (len(enum) < 2) enum = "0" // enum
      out = mant // "e" // esign // enum
    end if
    if (ieee_is_negative(x)) out = "-" // out
  end function fmt_g6

  !> ext_keys._fmt(value): %.6g of _num(value, 0.0).
  function fmt_of(v) result(out)
    type(dyn), intent(in) :: v
    character(len=:), allocatable :: out
    out = fmt_g6(num_default(v, 0.0_real64))
  end function fmt_of

  ! -----------------------------------------------------------------
  ! Python repr() helpers for %r diagnostic slots
  ! -----------------------------------------------------------------
  function repr_str(s) result(out)
    character(len=*), intent(in) :: s
    character(len=:), allocatable :: out, body
    character :: quote
    integer :: k, c
    logical :: has_sq, has_dq
    has_sq = index(s, "'") > 0
    has_dq = index(s, '"') > 0
    if (has_sq .and. .not. has_dq) then
      quote = '"'
    else
      quote = "'"
    end if
    body = ""
    do k = 1, len(s)
      c = iachar(s(k:k))
      if (s(k:k) == "\") then
        body = body // "\\"
      else if (s(k:k) == quote) then
        body = body // "\" // quote
      else if (c == 10) then
        body = body // "\n"
      else if (c == 13) then
        body = body // "\r"
      else if (c == 9) then
        body = body // "\t"
      else if (c < 32 .or. c == 127) then
        body = body // "\x" // hex2(c)
      else
        body = body // s(k:k)
      end if
    end do
    out = quote // body // quote
  end function repr_str

  function hex2(c) result(out)
    integer, intent(in) :: c
    character(2) :: out
    character(16), parameter :: HD = "0123456789abcdef"
    out(1:1) = HD(c / 16 + 1:c / 16 + 1)
    out(2:2) = HD(mod(c, 16) + 1:mod(c, 16) + 1)
  end function hex2

  !> Python repr(value).  Lists render as tuples, following the
  !! convention f3dc_validate established for dyn lists (the parser
  !! produces Python tuples for vec3-shaped values).
  recursive function py_repr(v) result(out)
    type(dyn), intent(in) :: v
    character(len=:), allocatable :: out, acc
    integer :: k
    select case (v%kind)
    case (DYN_K_STR)
      out = repr_str(s_of(v))
    case (DYN_K_BOOL)
      if (v%b) then
        out = "True"
      else
        out = "False"
      end if
    case (DYN_K_INT)
      out = fmt_int(v%i)
    case (DYN_K_REAL)
      out = fmt_real(v%r)
    case (DYN_K_LIST)
      acc = "("
      do k = 1, dyn_list_len(v)
        if (k > 1) acc = acc // ", "
        acc = acc // py_repr(dyn_list_at(v, k))
      end do
      if (dyn_list_len(v) == 1) acc = acc // ","
      out = acc // ")"
    case (DYN_K_DICT)
      acc = "{"
      do k = 1, dyn_dict_len(v)
        if (k > 1) acc = acc // ", "
        acc = acc // repr_str(dyn_dict_key_at(v, k)) // ": " // &
              py_repr(dyn_dict_value_at(v, k))
      end do
      out = acc // "}"
    case default
      out = "None"
    end select
  end function py_repr

  ! =================================================================
  ! Build (ext_keys.build_tracks)
  ! =================================================================

  !> _normalise_key(raw): defaults filled, frozen key order.
  function normalise_key(raw) result(key)
    type(dyn), intent(in) :: raw
    type(dyn) :: key, pos, rot
    real(real64) :: pv(3), rv(3)
    integer :: i
    key = dyn_dict()
    if (raw%kind == DYN_K_DICT) then
      call dyn_dict_set(key, "target", dyn_str(target_str( &
                        dget(raw, "target"))))
      call dyn_dict_set(key, "time", dyn_real(num_default( &
                        dget(raw, "time"), 0.0_real64)))
      call vec3_default(dget(raw, "pos"), DEF_POS, pv)
      call vec3_default(dget(raw, "rot"), DEF_ROT, rv)
      call dyn_dict_set(key, "scale", dyn_real(num_default( &
                        dget(raw, "scale"), 1.0_real64)))
      call dyn_dict_set(key, "ease", dyn_str(word_default( &
                        dget(raw, "ease"), DEFAULT_EASE)))
    else
      call dyn_dict_set(key, "target", dyn_str(""))
      call dyn_dict_set(key, "time", dyn_real(0.0_real64))
      pv = DEF_POS
      rv = DEF_ROT
      call dyn_dict_set(key, "scale", dyn_real(1.0_real64))
      call dyn_dict_set(key, "ease", dyn_str(DEFAULT_EASE))
    end if
    pos = dyn_list()
    rot = dyn_list()
    do i = 1, 3
      call dyn_list_push(pos, dyn_real(pv(i)))
      call dyn_list_push(rot, dyn_real(rv(i)))
    end do
    ! Python builds the dict literal in target,time,pos,rot,scale,
    ! ease order; rebuild in that order.
    block
      type(dyn) :: ordered
      ordered = dyn_dict()
      call dyn_dict_set(ordered, "target", dget(key, "target"))
      call dyn_dict_set(ordered, "time", dget(key, "time"))
      call dyn_dict_set(ordered, "pos", pos)
      call dyn_dict_set(ordered, "rot", rot)
      call dyn_dict_set(ordered, "scale", dget(key, "scale"))
      call dyn_dict_set(ordered, "ease", dget(key, "ease"))
      call dyn_assign(key, ordered)
    end block
  end function normalise_key

  !> _header_fields(header): (duration, loop) with defaults.
  !! Phase 5: also (fps, has_fps); fps is present only when the
  !! header carries a numeric "fps" entry.
  subroutine header_fields(header, duration, loop, fps, has_fps)
    type(dyn), intent(in) :: header
    real(real64), intent(out) :: duration
    character(len=:), allocatable, intent(out) :: loop
    real(real64), intent(out) :: fps
    logical, intent(out) :: has_fps
    real(real64) :: x
    logical :: has
    duration = 0.0_real64
    loop = DEFAULT_LOOP
    fps = 0.0_real64
    has_fps = .false.
    if (header%kind /= DYN_K_DICT) return
    call num_none(dget(header, "duration"), x, has)
    if (has) duration = x
    loop = word_default(dget(header, "loop"), DEFAULT_LOOP)
    call num_none(dget(header, "fps"), x, has)
    if (has) then
      fps = x
      has_fps = .true.
    end if
  end subroutine header_fields

  !> build_tracks(headers, keys) -> tracks dict.
  subroutine build_tracks(headers, keys, tracks)
    type(dyn), intent(in) :: headers, keys
    type(dyn), intent(out) :: tracks
    type(dyn) :: header, track, key, sorted, item
    character(len=:), allocatable :: name, loop
    real(real64) :: duration, fps
    logical :: has_fps
    integer :: k, i, j, n
    tracks = dyn_dict()
    if (headers%kind == DYN_K_DICT) then
      do k = 1, dyn_dict_len(headers)
        name = strip_ws(dyn_dict_key_at(headers, k))
        if (len(name) == 0) cycle
        header = dyn_dict_value_at(headers, k)
        call header_fields(header, duration, loop, fps, has_fps)
        track = dyn_dict()
        call dyn_dict_set(track, "duration", dyn_real(duration))
        call dyn_dict_set(track, "loop", dyn_str(loop))
        call dyn_dict_set(track, "keys", dyn_list())
        if (has_fps) call dyn_dict_set(track, "fps", dyn_real(fps))
        call dyn_dict_set(tracks, name, track)
      end do
    end if
    if (keys%kind == DYN_K_LIST) then
      do k = 1, dyn_list_len(keys)
        key = normalise_key(dyn_list_at(keys, k))
        name = s_of(dget(key, "target"))
        if (len(name) == 0) cycle
        if (dyn_dict_has(tracks, name)) then
          track = dyn_dict_get(tracks, name)
        else
          track = dyn_dict()
          call dyn_dict_set(track, "duration", dyn_real(0.0_real64))
          call dyn_dict_set(track, "loop", dyn_str(DEFAULT_LOOP))
          call dyn_dict_set(track, "keys", dyn_list())
        end if
        block
          type(dyn) :: klist
          klist = dget(track, "keys")
          call dyn_list_push(klist, key)
          call dyn_dict_set(track, "keys", klist)
        end block
        call dyn_dict_set(tracks, name, track)
      end do
    end if
    ! Stable sort of each track's keys by time (Python sorted()).
    do k = 1, dyn_dict_len(tracks)
      name = dyn_dict_key_at(tracks, k)
      track = dyn_dict_value_at(tracks, k)
      block
        type(dyn) :: klist
        type(dyn), allocatable :: items(:)
        real(real64), allocatable :: times(:)
        klist = dget(track, "keys")
        n = dyn_list_len(klist)
        if (n > 1) then
          allocate (items(n), times(n))
          do i = 1, n
            items(i) = dyn_list_at(klist, i)
            times(i) = num_default(dget(items(i), "time"), &
                                   0.0_real64)
          end do
          do i = 2, n
            call dyn_assign(item, items(i))
            block
              real(real64) :: tt
              tt = times(i)
              j = i - 1
              do while (j >= 1)
                if (.not. (times(j) > tt)) exit
                call dyn_assign(items(j + 1), items(j))
                times(j + 1) = times(j)
                j = j - 1
              end do
              call dyn_assign(items(j + 1), item)
              times(j + 1) = tt
            end block
          end do
          sorted = dyn_list()
          do i = 1, n
            call dyn_list_push(sorted, items(i))
          end do
          call dyn_dict_set(track, "keys", sorted)
          call dyn_dict_set(tracks, name, track)
          deallocate (items, times)
        end if
      end block
    end do
  end subroutine build_tracks

  ! =================================================================
  ! Validate (ext_keys.validate_tracks)
  ! =================================================================
  subroutine validate_tracks(tracks, errors)
    type(dyn), intent(in) :: tracks
    type(char_list), intent(inout) :: errors
    type(dyn) :: track, keys_list, key, raw
    character(len=:), allocatable :: name, loopw, easew, when_s
    real(real64) :: duration, when, scale, last_time, comp_x
    real(real64), allocatable :: seen(:)
    logical :: has_dur, has_when, has_last, has_scale, bad
    integer :: k, i, j, nseen, f
    if (tracks%kind /= DYN_K_DICT) return
    do k = 1, dyn_dict_len(tracks)
      name = dyn_dict_key_at(tracks, k)
      track = dyn_dict_value_at(tracks, k)
      if (track%kind /= DYN_K_DICT) then
        call char_list_append(errors, "track " // repr_str(name) // &
             " is not a track dict: a track must have 'duration', " // &
             "'loop' and 'keys'")
        cycle
      end if
      loopw = word_default(dget(track, "loop"), DEFAULT_LOOP)
      if (.not. (loopw == "once" .or. loopw == "forever" .or. &
                 loopw == "pingpong")) then
        call char_list_append(errors, "track " // repr_str(name) // &
             " has loop " // py_repr(dget(track, "loop")) // &
             ": 'loop' must be one of once, forever, pingpong")
      end if
      call num_none(dget(track, "duration"), duration, has_dur)
      if (has_dur .and. .not. ieee_is_finite(duration)) then
        call char_list_append(errors, "track " // repr_str(name) // &
             " has duration " // py_repr(dget(track, "duration")) // &
             ": 'duration' must be finite")
      end if
      block
        real(real64) :: fps_v
        logical :: has_fps_v
        call num_none(dget(track, "fps"), fps_v, has_fps_v)
        if (has_fps_v) then
          if (.not. ieee_is_finite(fps_v)) then
            call char_list_append(errors, "track " // repr_str(name) // &
                 " has fps " // py_repr(dget(track, "fps")) // &
                 ": 'fps' must be finite")
          else if (fps_v <= 0.0_real64) then
            call char_list_append(errors, "track " // repr_str(name) // &
                 " has fps " // fmt_g6(fps_v) // &
                 ": 'fps' must be greater than 0")
          end if
        end if
      end block
      keys_list = dget(track, "keys")
      if (keys_list%kind /= DYN_K_LIST .or. &
          dyn_list_len(keys_list) == 0) then
        call char_list_append(errors, "track " // repr_str(name) // &
             " has no keys: a track requires at least 1 key " // &
             "(a 'keys' header with no 'key' lines is an error)")
        cycle
      end if
      if (allocated(seen)) deallocate (seen)
      allocate (seen(dyn_list_len(keys_list)))
      nseen = 0
      has_last = .false.
      last_time = 0.0_real64
      do i = 1, dyn_list_len(keys_list)
        key = dyn_list_at(keys_list, i)
        if (key%kind /= DYN_K_DICT) then
          call char_list_append(errors, "track " // repr_str(name) // &
               " has a key that is not a dict: each key must have " // &
               "'time', 'pos', 'rot', 'scale' and 'ease'")
          cycle
        end if
        call num_none(dget(key, "time"), when, has_when)
        if (.not. has_when .or. .not. ieee_is_finite(when)) then
          call char_list_append(errors, "track " // repr_str(name) // &
               " has a key with time " // py_repr(dget(key, "time")) // &
               ": 'time' must be finite")
          when_s = "?"
          has_when = .false.
        else
          when_s = fmt_g6(when)
          if (when < 0.0_real64) then
            call char_list_append(errors, "track " // repr_str(name) // &
                 " has a key at time " // when_s // &
                 ": 'time' must not be negative")
          end if
          bad = .false.
          do j = 1, nseen
            if (seen(j) == when) bad = .true.
          end do
          if (bad) then
            call char_list_append(errors, "track " // repr_str(name) // &
                 " has duplicate key time " // when_s // &
                 ": key times must be strictly increasing " // &
                 "(duplicate times are an error)")
          end if
          nseen = nseen + 1
          seen(nseen) = when
          if (.not. has_last .or. when > last_time) then
            last_time = when
            has_last = .true.
          end if
        end if
        do f = 1, 2
          block
            character(3) :: field
            type(dyn) :: vec, comp
            integer :: ci
            if (f == 1) then
              field = "pos"
            else
              field = "rot"
            end if
            vec = dget(key, field)
            if (vec%kind == DYN_K_NULL) cycle
            if (vec%kind == DYN_K_LIST) then
              do ci = 1, dyn_list_len(vec)
                comp = dyn_list_at(vec, ci)
                call num_none(comp, comp_x, bad)
                if (.not. bad .or. .not. ieee_is_finite(comp_x)) then
                  call char_list_append(errors, "track " // &
                       repr_str(name) // " has a key at time " // &
                       when_s // " with " // field // " component " // &
                       py_repr(comp) // ": '" // field // &
                       "' values must be finite")
                  exit
                end if
              end do
            else
              call num_none(vec, comp_x, bad)
              if (.not. bad .or. .not. ieee_is_finite(comp_x)) then
                call char_list_append(errors, "track " // &
                     repr_str(name) // " has a key at time " // &
                     when_s // " with " // field // " component " // &
                     py_repr(vec) // ": '" // field // &
                     "' values must be finite")
              end if
            end if
          end block
        end do
        call num_none(dget(key, "scale"), scale, has_scale)
        if (.not. has_scale .or. .not. ieee_is_finite(scale)) then
          call char_list_append(errors, "track " // repr_str(name) // &
               " has a key at time " // when_s // " with scale " // &
               py_repr(dget(key, "scale")) // ": 'scale' must be finite")
        else if (scale <= 0.0_real64) then
          call char_list_append(errors, "track " // repr_str(name) // &
               " has a key at time " // when_s // " with scale " // &
               fmt_g6(scale) // ": 'scale' must be greater than 0")
        end if
        easew = word_default(dget(key, "ease"), DEFAULT_EASE)
        if (.not. (easew == "linear" .or. easew == "smooth" .or. &
                   easew == "in" .or. easew == "out" .or. &
                   easew == "cubic-in" .or. easew == "cubic-out" .or. &
                   easew == "cubic-in-out")) then
          call char_list_append(errors, "track " // repr_str(name) // &
               " has a key at time " // when_s // " with ease " // &
               py_repr(dget(key, "ease")) // &
               ": 'ease' must be one of linear, smooth, in, out, " // &
               "cubic-in, cubic-out, cubic-in-out")
        end if
      end do
      if (has_dur .and. ieee_is_finite(duration) .and. &
          duration > 0.0_real64 .and. has_last .and. &
          duration < last_time) then
        call char_list_append(errors, "track " // repr_str(name) // &
             " has duration " // fmt_g6(duration) // &
             " before its last key at time " // fmt_g6(last_time) // &
             ": 'duration' must be at least the last key time")
      end if
    end do
    if (allocated(seen)) deallocate (seen)
  end subroutine validate_tracks

  ! =================================================================
  ! Emit lines (ext_keys.track_lines) -- the .scene keyframe hook
  ! =================================================================
  subroutine track_lines(target, track, lines)
    character(len=*), intent(in) :: target
    type(dyn), intent(in) :: track
    type(char_list), intent(inout) :: lines
    type(dyn) :: keys_list, key
    character(len=:), allocatable :: loopw, line
    real(real64) :: duration, pv(3), rv(3), fps_v
    logical :: has_dur, has_fps_v
    integer :: i
    fps_v = 0.0_real64
    has_fps_v = .false.
    if (track%kind == DYN_K_DICT) then
      call num_none(dget(track, "duration"), duration, has_dur)
      if (.not. has_dur) duration = 0.0_real64
      loopw = word_default(dget(track, "loop"), DEFAULT_LOOP)
      keys_list = dget(track, "keys")
      call num_none(dget(track, "fps"), fps_v, has_fps_v)
    else
      duration = 0.0_real64
      loopw = DEFAULT_LOOP
      keys_list = dyn_null()
    end if
    if (keys_list%kind /= DYN_K_LIST) keys_list = dyn_list()
    ! Phase 5: optional trailing " fps <fps>" token pair, emitted
    ! only when the track carries fps (zero drift otherwise).
    if (has_fps_v) then
      call char_list_append(lines, "keys " // target // " " // &
           fmt_g6(duration) // " " // loopw // " " // &
           fmt_int(int(dyn_list_len(keys_list), int64)) // &
           " fps " // fmt_g6(fps_v))
    else
      call char_list_append(lines, "keys " // target // " " // &
           fmt_g6(duration) // " " // loopw // " " // &
           fmt_int(int(dyn_list_len(keys_list), int64)))
    end if
    do i = 1, dyn_list_len(keys_list)
      key = dyn_list_at(keys_list, i)
      if (key%kind /= DYN_K_DICT) key = dyn_dict()
      call vec3_default(dget(key, "pos"), DEF_POS, pv)
      call vec3_default(dget(key, "rot"), DEF_ROT, rv)
      line = "key " // fmt_g6(num_default(dget(key, "time"), &
             0.0_real64)) // " " // &
             fmt_g6(pv(1)) // " " // fmt_g6(pv(2)) // " " // &
             fmt_g6(pv(3)) // " " // &
             fmt_g6(rv(1)) // " " // fmt_g6(rv(2)) // " " // &
             fmt_g6(rv(3)) // " " // &
             fmt_g6(num_default(dget(key, "scale"), 1.0_real64)) // &
             " " // word_default(dget(key, "ease"), DEFAULT_EASE)
      call char_list_append(lines, line)
    end do
  end subroutine track_lines

end module f3dc_ext_keys
