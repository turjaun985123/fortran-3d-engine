! f3dc_errors.f90 -- diagnostics for the native Forge3D compiler.
! Port of tools/f3dc/errors.py (read in full) plus the rendering call
! in tools/f3dc/cli.py::_print_diagnostics:
!   text form  -> error_bag_format_text  (printed to stderr by the CLI)
!   JSON form  -> error_bag_format_json  (bag.format_json(), --json)
!
! Codes, severities, spans, why/help texts and both rendered formats
! match the Python byte for byte for ASCII input.  See the report for
! the two Unicode corners (splitlines / json \u escapes) and how they
! are handled.
module f3dc_errors
  use, intrinsic :: iso_fortran_env, only: int64, real64
  use f3dc_str, only: char_list, char_list_len, char_list_at, to_lower, &
                      fmt_int
  implicit none
  private

  public :: span_t, diagnostic_t, error_bag_t
  public :: make_span, make_diagnostic, make_diagnostic_span
  public :: error_code_title, error_code_count
  public :: error_bag_add, error_bag_set_source
  public :: error_bag_len, error_bag_at
  public :: error_bag_error_count, error_bag_warning_count
  public :: error_bag_has_errors, error_bag_fail_code
  public :: error_bag_format_text, error_bag_format_json
  public :: expand_tabs, json_escape
  public :: damerau_levenshtein, did_you_mean

  !> A location in a source file. line/col are 1-based (Span).
  type :: span_t
    character(len=:), allocatable :: source
    integer :: line = 1
    integer :: col = 1
    integer :: length = 1
  end type span_t

  !> One user-facing diagnostic (Diagnostic).
  type :: diagnostic_t
    character(len=:), allocatable :: code
    character(len=:), allocatable :: severity  ! "error" | "warning"
    character(len=:), allocatable :: message
    logical :: has_span = .false.
    type(span_t) :: span
    character(len=:), allocatable :: why
    character(len=:), allocatable :: help
  end type diagnostic_t

  !> Collects diagnostics from every compiler stage (ErrorBag).
  type :: error_bag_t
    type(diagnostic_t), allocatable :: diags(:)
    integer :: n = 0
    integer :: cap = 0
    character(len=:), allocatable :: source_text
    logical :: has_source = .false.
  end type error_bag_t

  ! ERROR_CODES: stable, append-only code -> short title (errors.py).
  integer, parameter :: N_CODES = 21
  character(len=4), parameter :: CODE_KEYS(N_CODES) = [ &
    "E101", "E102", "E103", "E104", "E110", &
    "E201", "E202", "E203", "E204", "E205", &
    "E301", "E302", "E303", "E401", "E402", &
    "E501", "E502", "E820", "W101", "W102", &
    "W201"]
  character(len=32), parameter :: CODE_TITLES(N_CODES) = [ &
    "unexpected token              ", &
    "expected number               ", &
    "unterminated string           ", &
    "unknown statement             ", &
    "duplicate property            ", &
    "unknown name/target           ", &
    "unknown colour                ", &
    "unknown primitive             ", &
    "texture not in v1             ", &
    "reserved keyword              ", &
    "value out of range            ", &
    "non-positive size             ", &
    "fov range                     ", &
    "structure (group/end mismatch)", &
    "no objects                    ", &
    "file not found                ", &
    "cannot write output           ", &
    "security/limit violation      ", &
    "default injected              ", &
    "statement replaced            ", &
    "animation defaulted           "]

contains

  ! ------------------------------------------------------------------
  ! ERROR_CODES lookup
  ! ------------------------------------------------------------------

  pure integer function error_code_count()
    error_code_count = 21  ! entries in the Python ERROR_CODES dict
  end function error_code_count

  !> Title for a code; found=.false. when the code is not in the table.
  subroutine error_code_title(code, title, found)
    character(len=*), intent(in) :: code
    character(len=:), allocatable, intent(out) :: title
    logical, intent(out) :: found
    integer :: k
    found = .false.
    title = ""
    do k = 1, 21
      if (len(code) == 4 .and. code == CODE_KEYS(k)) then
        title = trim(CODE_TITLES(k))
        found = .true.
        return
      end if
    end do
  end subroutine error_code_title

  ! ------------------------------------------------------------------
  ! Constructors (Span / Diagnostic dataclasses)
  ! ------------------------------------------------------------------

  function make_span(source, line, col, length) result(sp)
    character(len=*), intent(in) :: source
    integer, intent(in) :: line, col
    integer, intent(in), optional :: length
    type(span_t) :: sp
    sp%source = source
    sp%line = line
    sp%col = col
    if (present(length)) then
      sp%length = length
    else
      sp%length = 1
    end if
  end function make_span

  function make_diagnostic(code, severity, message, why, help) result(diag)
    character(len=*), intent(in) :: code, severity, message
    character(len=*), intent(in), optional :: why, help
    type(diagnostic_t) :: diag
    diag%code = code
    diag%severity = severity
    diag%message = message
    diag%has_span = .false.
    if (present(why)) then
      diag%why = why
    else
      diag%why = ""
    end if
    if (present(help)) then
      diag%help = help
    else
      diag%help = ""
    end if
  end function make_diagnostic

  function make_diagnostic_span(code, severity, message, span, why, &
                                help) result(diag)
    character(len=*), intent(in) :: code, severity, message
    type(span_t), intent(in) :: span
    character(len=*), intent(in), optional :: why, help
    type(diagnostic_t) :: diag
    diag = make_diagnostic(code, severity, message, why, help)
    diag%has_span = .true.
    diag%span = span
  end function make_diagnostic_span

  ! ------------------------------------------------------------------
  ! ErrorBag: collection and queries
  ! ------------------------------------------------------------------

  subroutine error_bag_add(bag, diag)
    type(error_bag_t), intent(inout) :: bag
    type(diagnostic_t), intent(in) :: diag
    type(diagnostic_t), allocatable :: tmp(:)
    integer :: newcap, k
    if (bag%n >= bag%cap) then
      newcap = max(4, 2 * bag%cap)
      allocate (tmp(newcap))
      do k = 1, bag%n
        tmp(k) = bag%diags(k)
      end do
      call move_alloc(tmp, bag%diags)
      bag%cap = newcap
    end if
    bag%n = bag%n + 1
    bag%diags(bag%n) = diag
  end subroutine error_bag_add

  !> Provide the source text so format_text() can show snippets.
  subroutine error_bag_set_source(bag, text)
    type(error_bag_t), intent(inout) :: bag
    character(len=*), intent(in) :: text
    bag%source_text = text
    bag%has_source = .true.
  end subroutine error_bag_set_source

  pure integer function error_bag_len(bag)
    type(error_bag_t), intent(in) :: bag
    error_bag_len = bag%n
  end function error_bag_len

  !> 1-based diagnostic access; caller must keep idx within 1..n.
  function error_bag_at(bag, idx) result(diag)
    type(error_bag_t), intent(in) :: bag
    integer, intent(in) :: idx
    type(diagnostic_t) :: diag
    diag = bag%diags(idx)
  end function error_bag_at

  integer function error_bag_error_count(bag)
    type(error_bag_t), intent(in) :: bag
    integer :: k
    error_bag_error_count = 0
    do k = 1, bag%n
      if (str_of(bag%diags(k)%severity) == "error") &
        error_bag_error_count = error_bag_error_count + 1
    end do
  end function error_bag_error_count

  integer function error_bag_warning_count(bag)
    type(error_bag_t), intent(in) :: bag
    integer :: k
    error_bag_warning_count = 0
    do k = 1, bag%n
      if (str_of(bag%diags(k)%severity) == "warning") &
        error_bag_warning_count = error_bag_warning_count + 1
    end do
  end function error_bag_warning_count

  logical function error_bag_has_errors(bag)
    type(error_bag_t), intent(in) :: bag
    error_bag_has_errors = error_bag_error_count(bag) > 0
  end function error_bag_has_errors

  !> cli.py::_fail_code -- E5xx IO -> 3, else scene errors -> 1.
  !! (0 when the bag holds no errors at all.)
  integer function error_bag_fail_code(bag)
    type(error_bag_t), intent(in) :: bag
    integer :: k
    if (.not. error_bag_has_errors(bag)) then
      error_bag_fail_code = 0
      return
    end if
    error_bag_fail_code = 1
    do k = 1, bag%n
      block
        character(len=:), allocatable :: code_k
        code_k = str_of(bag%diags(k)%code)
        if (str_of(bag%diags(k)%severity) == "error" .and. &
            len(code_k) >= 2 .and. code_k(1:2) == "E5") then
          error_bag_fail_code = 3
          return
        end if
      end block
    end do
  end function error_bag_fail_code

  ! ------------------------------------------------------------------
  ! Helpers
  ! ------------------------------------------------------------------

  !> Allocated-or-empty view of an allocatable string component.
  function str_of(s) result(out)
    character(len=:), allocatable, intent(in) :: s
    character(len=:), allocatable :: out
    if (allocated(s)) then
      out = s
    else
      out = ""
    end if
  end function str_of

  !> Python str.expandtabs(8): a tab advances to the next multiple
  !! of 8 columns (columns counted in characters).
  function expand_tabs(s) result(out)
    character(len=*), intent(in) :: s
    character(len=:), allocatable :: out
    integer :: i, col, nsp
    out = ""
    col = 0
    do i = 1, len(s)
      if (s(i:i) == achar(9)) then
        nsp = 8 - mod(col, 8)
        out = out // repeat(" ", nsp)
        col = col + nsp
      else
        out = out // s(i:i)
        col = col + 1
      end if
    end do
  end function expand_tabs

  !> Fetch 1-based line idx (0-based Python index line_no-1 handled by
  !! the caller passing span line) from text, splitlines-style for
  !! LF / CRLF / CR endings.  found=.false. when out of range.
  subroutine get_source_line(text, line_no, line, found)
    character(len=*), intent(in) :: text
    integer, intent(in) :: line_no
    character(len=:), allocatable, intent(out) :: line
    logical, intent(out) :: found
    integer :: pos, cur, start, eol
    found = .false.
    line = ""
    if (line_no < 1) return
    pos = 1
    cur = 1
    do while (pos <= len(text))
      start = pos
      eol = index(text(pos:), achar(10))
      if (eol == 0) then
        if (cur == line_no) then
          line = text(start:)
          ! A trailing CR belongs to a CRLF ending only when followed
          ! by LF; a lone final line keeps its bytes except that
          ! Python splitlines also splits on a trailing CR.
          if (len(line) > 0) then
            if (line(len(line):len(line)) == achar(13)) &
              line = line(1:len(line) - 1)
          end if
          found = .true.
        end if
        return
      end if
      if (cur == line_no) then
        line = text(start:start + eol - 2)
        if (len(line) > 0) then
          if (line(len(line):len(line)) == achar(13)) &
            line = line(1:len(line) - 1)
        end if
        found = .true.
        return
      end if
      cur = cur + 1
      pos = start + eol
    end do
    ! Text ending in a newline has no further line (splitlines agrees).
  end subroutine get_source_line

  ! ------------------------------------------------------------------
  ! format_text (ErrorBag.format_text)
  ! ------------------------------------------------------------------

  !> Snippet lines for one diagnostic: [expanded line, caret line],
  !! or nothing when there is no source text / span / line in range.
  subroutine snippet_lines(bag, diag, text_line, caret, have)
    type(error_bag_t), intent(in) :: bag
    type(diagnostic_t), intent(in) :: diag
    character(len=:), allocatable, intent(out) :: text_line, caret
    logical, intent(out) :: have
    character(len=:), allocatable :: raw, prefix
    logical :: found
    have = .false.
    text_line = ""
    caret = ""
    if (.not. bag%has_source .or. .not. diag%has_span) return
    call get_source_line(bag%source_text, diag%span%line, raw, found)
    if (.not. found) return
    text_line = expand_tabs(raw)
    if (diag%span%col > 1) then
      prefix = raw(1:min(len(raw), diag%span%col - 1))
    else
      prefix = ""
    end if
    caret = repeat(" ", len(expand_tabs(prefix))) // &
            repeat("^", max(1, diag%span%length))
    have = .true.
  end subroutine snippet_lines

  !> ErrorBag.format_text(use_color): blocks joined by a single "\n",
  !! no trailing newline; "" for an empty bag.
  function error_bag_format_text(bag, use_color) result(out)
    type(error_bag_t), intent(in) :: bag
    logical, intent(in), optional :: use_color
    character(len=:), allocatable :: out
    logical :: colour
    integer :: k
    character(len=:), allocatable :: header, tl, caret, block_text
    logical :: have
    colour = .false.
    if (present(use_color)) colour = use_color
    out = ""
    do k = 1, bag%n
      associate (diag => bag%diags(k))
        if (diag%has_span) then
          header = str_of(diag%span%source) // ":" // &
                   trim(fmt_int(int(diag%span%line, int64))) // ":" // &
                   trim(fmt_int(int(diag%span%col, int64))) // ": " // &
                   str_of(diag%severity) // " " // str_of(diag%code) // &
                   ": " // str_of(diag%message)
        else
          header = str_of(diag%severity) // " " // str_of(diag%code) // &
                   ": " // str_of(diag%message)
        end if
        if (colour) then
          if (str_of(diag%severity) == "error") then
            header = achar(27) // "[1;31m" // header // achar(27) // "[0m"
          else
            header = achar(27) // "[1;33m" // header // achar(27) // "[0m"
          end if
        end if
        block_text = header
        call snippet_lines(bag, diag, tl, caret, have)
        if (have) block_text = block_text // achar(10) // tl // &
                               achar(10) // caret
        if (len(str_of(diag%why)) > 0) &
          block_text = block_text // achar(10) // "  why: " // &
                       str_of(diag%why)
        if (len(str_of(diag%help)) > 0) &
          block_text = block_text // achar(10) // "  help: " // &
                       str_of(diag%help)
      end associate
      if (k > 1) out = out // achar(10)
      out = out // block_text
    end do
  end function error_bag_format_text

  ! ------------------------------------------------------------------
  ! format_json (ErrorBag.format_json == json.dumps(records, indent=2))
  ! ------------------------------------------------------------------

  !> "\uXXXX" for a code point < 65536, with LOWERCASE hex digits
  !! (Python json.dumps style).  Fortran's Z edit descriptor emits
  !! UPPERCASE hex, so the digits are built by hand here.
  function json_u_escape(cp) result(out)
    integer, intent(in) :: cp
    character(len=6) :: out
    character(len=*), parameter :: HEXD = "0123456789abcdef"
    integer :: n, d
    n = cp
    out(1:2) = "\u"
    do d = 6, 3, -1
      out(d:d) = HEXD(mod(n, 16) + 1:mod(n, 16) + 1)
      n = n / 16
    end do
  end function json_u_escape

  !> JSON string escaping, json.dumps defaults (ensure_ascii=True):
  !! \" \\ \b \f \n \r \t, other control chars as \u00xx, and
  !! non-ASCII (UTF-8 decoded) as \uXXXX with surrogate pairs.
  function json_escape(s) result(out)
    character(len=*), intent(in) :: s
    character(len=:), allocatable :: out
    integer :: i, b, cp, nbytes, j
    out = ""
    i = 1
    do while (i <= len(s))
      b = iachar(s(i:i))
      if (b < 128) then
        select case (b)
        case (34)
          out = out // '\"'
        case (92)
          out = out // '\\'
        case (8)
          out = out // '\b'
        case (12)
          out = out // '\f'
        case (10)
          out = out // '\n'
        case (13)
          out = out // '\r'
        case (9)
          out = out // '\t'
        case (0:7, 11, 14:31, 127)
          out = out // json_u_escape(b)
        case default
          out = out // s(i:i)
        end select
        i = i + 1
      else
        ! Decode one UTF-8 sequence to its code point.
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
          cp = b  ! stray continuation byte: emit as \u00xx
        end if
        if (nbytes > 1) then
          do j = 1, nbytes - 1
            if (i + j > len(s)) exit
            cp = cp * 64 + mod(iachar(s(i + j:i + j)), 64)
          end do
        end if
        if (cp <= 65535) then
          out = out // json_u_escape(cp)
        else
          block
            integer :: hi, lo
            hi = 55296 + (cp - 65536) / 1024
            lo = 56320 + mod(cp - 65536, 1024)
            out = out // json_u_escape(hi)
            out = out // json_u_escape(lo)
          end block
        end if
        i = i + nbytes
      end if
    end do
  end function json_escape

  function json_str(s) result(out)
    character(len=*), intent(in) :: s
    character(len=:), allocatable :: out
    out = '"' // json_escape(s) // '"'
  end function json_str

  !> ErrorBag.format_json(): json.dumps(records, indent=2) exactly.
  function error_bag_format_json(bag) result(out)
    type(error_bag_t), intent(in) :: bag
    character(len=:), allocatable :: out
    character(len=*), parameter :: NL = achar(10)
    integer :: k
    if (bag%n == 0) then
      out = "[]"
      return
    end if
    out = "[" // NL
    do k = 1, bag%n
      associate (diag => bag%diags(k))
        out = out // "  {" // NL
        out = out // '    "code": ' // json_str(str_of(diag%code)) // &
              "," // NL
        out = out // '    "severity": ' // &
              json_str(str_of(diag%severity)) // "," // NL
        out = out // '    "message": ' // &
              json_str(str_of(diag%message)) // "," // NL
        if (diag%has_span) then
          out = out // '    "file": ' // &
                json_str(str_of(diag%span%source)) // "," // NL
          out = out // '    "line": ' // &
                trim(fmt_int(int(diag%span%line, int64))) // "," // NL
          out = out // '    "col": ' // &
                trim(fmt_int(int(diag%span%col, int64))) // "," // NL
          out = out // '    "span": {' // NL
          out = out // '      "source": ' // &
                json_str(str_of(diag%span%source)) // "," // NL
          out = out // '      "line": ' // &
                trim(fmt_int(int(diag%span%line, int64))) // "," // NL
          out = out // '      "col": ' // &
                trim(fmt_int(int(diag%span%col, int64))) // "," // NL
          out = out // '      "length": ' // &
                trim(fmt_int(int(diag%span%length, int64))) // NL
          out = out // "    }," // NL
        else
          out = out // '    "file": null,' // NL
          out = out // '    "line": null,' // NL
          out = out // '    "col": null,' // NL
          out = out // '    "span": null,' // NL
        end if
        out = out // '    "why": ' // json_str(str_of(diag%why)) // &
              "," // NL
        out = out // '    "help": ' // json_str(str_of(diag%help)) // NL
        if (k < bag%n) then
          out = out // "  }," // NL
        else
          out = out // "  }" // NL
        end if
      end associate
    end do
    out = out // "]"
  end function error_bag_format_json

  ! ------------------------------------------------------------------
  ! did-you-mean (errors.py: true Damerau-Levenshtein)
  ! ------------------------------------------------------------------

  !> True Damerau-Levenshtein distance (transposition counts as 1).
  !! Byte-oriented: identical to the Python for ASCII; Python counts
  !! Unicode code points (see report).
  integer function damerau_levenshtein(a, b)
    character(len=*), intent(in) :: a, b
    integer :: len_a, len_b, maxdist, i, j, i1, j1, cost, last_match_col
    integer, allocatable :: d(:, :)
    integer :: last_row(0:255)
    len_a = len(a)
    len_b = len(b)
    if (len_a == 0) then
      damerau_levenshtein = len_b
      return
    end if
    if (len_b == 0) then
      damerau_levenshtein = len_a
      return
    end if
    maxdist = len_a + len_b
    allocate (d(0:len_a + 1, 0:len_b + 1))
    d = 0
    d(0, 0) = maxdist
    do i = 0, len_a
      d(i + 1, 0) = maxdist
      d(i + 1, 1) = i
    end do
    do j = 0, len_b
      d(0, j + 1) = maxdist
      d(1, j + 1) = j
    end do
    last_row = 0
    do i = 1, len_a
      last_match_col = 0
      do j = 1, len_b
        i1 = last_row(iachar(b(j:j)))
        j1 = last_match_col
        cost = 1
        if (a(i:i) == b(j:j)) then
          cost = 0
          last_match_col = j
        end if
        d(i + 1, j + 1) = min(d(i, j) + cost, &
                              d(i + 1, j) + 1, &
                              d(i, j + 1) + 1, &
                              d(i1, j1) + (i - i1 - 1) + 1 + (j - j1 - 1))
      end do
      last_row(iachar(a(i:i))) = i
    end do
    damerau_levenshtein = d(len_a + 1, len_b + 1)
    deallocate (d)
  end function damerau_levenshtein

  !> Closest candidate within distance 2, case-insensitive; the
  !! candidate is returned as written.  found=.false. = Python None.
  subroutine did_you_mean(word, candidates, result, found)
    character(len=*), intent(in) :: word
    type(char_list), intent(in) :: candidates
    character(len=:), allocatable, intent(out) :: result
    logical, intent(out) :: found
    character(len=:), allocatable :: lowered, cand
    integer :: k, dist, best_dist
    result = ""
    found = .false.
    if (len(word) == 0 .or. char_list_len(candidates) == 0) return
    lowered = to_lower(word)
    best_dist = 3  ! one past the <= 2 threshold
    do k = 1, char_list_len(candidates)
      cand = char_list_at(candidates, k)
      if (len(cand) == 0) cycle
      dist = damerau_levenshtein(lowered, to_lower(cand))
      if (dist < best_dist) then
        best_dist = dist
        result = cand
        found = .true.
        if (dist == 0) return
      end if
    end do
  end subroutine did_you_mean

end module f3dc_errors
