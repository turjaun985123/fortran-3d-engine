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
  use, intrinsic :: iso_c_binding, only: c_int
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
  public :: error_bag_use_color, error_bag_debug_text

  ! C helper in compiler/preview_http.c (always linked into f3dc):
  ! isatty(2) for stderr, following the f3dc_preview.f90 pattern.
  interface
    function f3dc_isatty_stderr() bind(C, name="f3dc_isatty_stderr") &
        result(rc)
      import :: c_int
      integer(c_int) :: rc
    end function f3dc_isatty_stderr
  end interface
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

  !> One heap-held string, used to assemble large formatted output
  !! without repeated self-concatenation (see error_bag_format_text).
  type :: str_box_t
    character(len=:), allocatable :: s
  end type str_box_t

  ! ERROR_CODES: stable, append-only code -> short title (errors.py).
  integer, parameter :: N_CODES = 22
  character(len=4), parameter :: CODE_KEYS(N_CODES) = [ &
    "E101", "E102", "E103", "E104", "E110", &
    "E201", "E202", "E203", "E204", "E205", &
    "E301", "E302", "E303", "E401", "E402", &
    "E501", "E502", "E504", "E820", "W101", &
    "W102", "W201"]
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
    "import cycle                  ", &
    "security/limit violation      ", &
    "default injected              ", &
    "statement replaced            ", &
    "animation defaulted           "]

contains

  ! ------------------------------------------------------------------
  ! ERROR_CODES lookup
  ! ------------------------------------------------------------------

  pure integer function error_code_count()
    error_code_count = 22  ! entries in the ERROR_CODES table (E504 is
                           ! native-only: import cycle, v2.0 P3)
  end function error_code_count

  !> Title for a code; found=.false. when the code is not in the table.
  subroutine error_code_title(code, title, found)
    character(len=*), intent(in) :: code
    character(len=:), allocatable, intent(out) :: title
    logical, intent(out) :: found
    integer :: k
    found = .false.
    title = ""
    do k = 1, N_CODES
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

  !> True when environment variable NAME is PRESENT, whatever its
  !! value (including empty).  get_environment_variable reports
  !! status 0 for a present variable (length 0 when empty) and a
  !! non-zero status when it does not exist -- this is the presence
  !! test the NO_COLOR convention requires.
  logical function env_present(name)
    character(len=*), intent(in) :: name
    integer :: st, ln
    call get_environment_variable(name, length=ln, status=st)
    env_present = (st == 0)
  end function env_present

  !> Colour decision for the text diagnostic form (v2.0 P4, closing
  !! the REPLACEMENT.md divergence): colours ON only when stderr is
  !! a TTY and NO_COLOR is not present -- the deleted Python
  !! compiler's rule.  Piped output therefore stays byte-identical
  !! to the pre-P4 binary.
  logical function error_bag_use_color()
    if (env_present("NO_COLOR")) then
      error_bag_use_color = .false.
      return
    end if
    if (f3dc_isatty_stderr() == 0_c_int) then
      error_bag_use_color = .false.
      return
    end if
    error_bag_use_color = .true.
  end function error_bag_use_color

  !> One `debug: ` line for ONE diagnostic, built in its own
  !! subroutine for the stack reason given at diag_block_text.
  subroutine diag_debug_line(diag, line)
    type(diagnostic_t), intent(in) :: diag
    character(len=:), allocatable, intent(out) :: line
    line = "debug: code=" // str_of(diag%code) // &
           " severity=" // str_of(diag%severity) // &
           " file=" // str_of(diag%span%source) // &
           " line=" // trim(fmt_int(int(diag%span%line, int64))) // &
           " col=" // trim(fmt_int(int(diag%span%col, int64))) // &
           " message=" // str_of(diag%message)
  end subroutine diag_debug_line

  !> Internal diagnostic dump for F3DC_DEBUG (v2.0 P4).  Returns ""
  !! when F3DC_DEBUG is not present, so callers emit nothing extra
  !! and default output stays byte-identical.  When present, one
  !! `debug: ` line per diagnostic carrying its internal fields.
  !! NOTE: there is no live E9000 raise site in the native compiler
  !! -- Fortran has no exceptions to catch -- so this print-time
  !! internal dump is the native equivalent of the Python oracle's
  !! F3DC_DEBUG traceback mode.
  function error_bag_debug_text(bag) result(out)
    type(error_bag_t), intent(in) :: bag
    character(len=:), allocatable :: out
    integer :: k, total, pos, lb
    type(str_box_t), allocatable :: lines(:)
    out = ""
    if (.not. env_present("F3DC_DEBUG")) return
    if (bag%n == 0) return
    allocate (lines(bag%n))
    total = bag%n - 1  ! single-"\n" separators, as format_text
    do k = 1, bag%n
      call diag_debug_line(bag%diags(k), lines(k)%s)
      total = total + len(lines(k)%s)
    end do
    allocate (character(len=total) :: out)
    pos = 1
    do k = 1, bag%n
      if (k > 1) then
        out(pos:pos) = achar(10)
        pos = pos + 1
      end if
      lb = len(lines(k)%s)
      if (lb > 0) then
        out(pos:pos + lb - 1) = lines(k)%s
        pos = pos + lb
      end if
    end do
  end function error_bag_debug_text

  !> Python str.expandtabs(8): a tab advances to the next multiple
  !! of 8 columns (columns counted in characters).
  function expand_tabs(s) result(out)
    character(len=*), intent(in) :: s
    character(len=:), allocatable :: out
    character(len=:), allocatable :: buf
    integer :: i, col, nsp, used
    ! Fill a preallocated buffer by position.  The previous
    ! char-by-char `out = out // ...` loop is not just quadratic:
    ! flang-18 alloca's each concatenation temporary on the stack
    ! and does not reclaim it until this function returns, so the
    ! stack cost is the SUM of every intermediate length (~len^2/2)
    ! and a long line can overflow the main-thread stack.
    allocate (character(len=8 * len(s)) :: buf)
    used = 0
    col = 0
    do i = 1, len(s)
      if (s(i:i) == achar(9)) then
        nsp = 8 - mod(col, 8)
        buf(used + 1:used + nsp) = repeat(" ", nsp)
        used = used + nsp
        col = col + nsp
      else
        used = used + 1
        buf(used:used) = s(i:i)
        col = col + 1
      end if
    end do
    if (used > 0) then
      out = buf(1:used)
    else
      out = ""
    end if
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

  !> The formatted block for ONE diagnostic (header + optional
  !! snippet/caret + optional why/help lines).  This lives in its
  !! own subroutine on purpose: flang-18 alloca's deferred-length
  !! concatenation temporaries on the stack and does not reclaim
  !! them until the enclosing procedure returns, so building every
  !! block inside error_bag_format_text's loop made the stack cost
  !! the sum of all blocks' intermediate lengths and a flood of
  !! diagnostics (tens of KB of output) overflowed the 8 MiB
  !! main-thread stack -> SIGSEGV at the assembly concatenations.
  !! Per-diagnostic temporaries are bounded by one block and are
  !! released when this subroutine returns.
  subroutine diag_block_text(bag, diag, colour, block_text)
    type(error_bag_t), intent(in) :: bag
    type(diagnostic_t), intent(in) :: diag
    logical, intent(in) :: colour
    character(len=:), allocatable, intent(out) :: block_text
    character(len=:), allocatable :: header, tl, caret
    logical :: have
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
  end subroutine diag_block_text

  !> ErrorBag.format_text(use_color): blocks joined by a single "\n",
  !! no trailing newline; "" for an empty bag.
  function error_bag_format_text(bag, use_color) result(out)
    type(error_bag_t), intent(in) :: bag
    logical, intent(in), optional :: use_color
    character(len=:), allocatable :: out
    logical :: colour
    integer :: k, total, pos, lb
    type(str_box_t), allocatable :: blocks(:)
    colour = .false.
    if (present(use_color)) colour = use_color
    if (bag%n == 0) then
      out = ""
      return
    end if
    ! Build each block separately (heap-held), then assemble into a
    ! single preallocated buffer filled by position.  The previous
    ! `out = out // block_text` loop stack-overflowed on large
    ! diagnostic counts (see diag_block_text): with ~105+ diagnostics
    ! over a ~460-char line (or ~170 single-line E101s) the native
    ! compiler died with SIGSEGV and no output at all.
    allocate (blocks(bag%n))
    total = bag%n - 1  ! the single-"\n" separators
    do k = 1, bag%n
      call diag_block_text(bag, bag%diags(k), colour, blocks(k)%s)
      total = total + len(blocks(k)%s)
    end do
    allocate (character(len=total) :: out)
    pos = 1
    do k = 1, bag%n
      if (k > 1) then
        out(pos:pos) = achar(10)
        pos = pos + 1
      end if
      lb = len(blocks(k)%s)
      if (lb > 0) then
        out(pos:pos + lb - 1) = blocks(k)%s
        pos = pos + lb
      end if
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
    character(len=:), allocatable :: buf
    integer :: i, b, cp, nbytes, j, used
    ! Preallocated buffer filled by position (worst case per input
    ! byte is one 6-char \uXXXX escape); the previous char-by-char
    ! self-concatenation had the same stack-accumulating alloca
    ! behaviour described in diag_block_text.
    allocate (character(len=6 * len(s) + 6) :: buf)
    used = 0
    i = 1
    do while (i <= len(s))
      b = iachar(s(i:i))
      if (b < 128) then
        select case (b)
        case (34)
          buf(used + 1:used + 2) = '\"'
          used = used + 2
        case (92)
          buf(used + 1:used + 2) = '\\'
          used = used + 2
        case (8)
          buf(used + 1:used + 2) = '\b'
          used = used + 2
        case (12)
          buf(used + 1:used + 2) = '\f'
          used = used + 2
        case (10)
          buf(used + 1:used + 2) = '\n'
          used = used + 2
        case (13)
          buf(used + 1:used + 2) = '\r'
          used = used + 2
        case (9)
          buf(used + 1:used + 2) = '\t'
          used = used + 2
        case (0:7, 11, 14:31, 127)
          buf(used + 1:used + 6) = json_u_escape(b)
          used = used + 6
        case default
          used = used + 1
          buf(used:used) = s(i:i)
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
          buf(used + 1:used + 6) = json_u_escape(cp)
          used = used + 6
        else
          block
            integer :: hi, lo
            hi = 55296 + (cp - 65536) / 1024
            lo = 56320 + mod(cp - 65536, 1024)
            buf(used + 1:used + 6) = json_u_escape(hi)
            buf(used + 7:used + 12) = json_u_escape(lo)
            used = used + 12
          end block
        end if
        i = i + nbytes
      end if
    end do
    if (used > 0) then
      out = buf(1:used)
    else
      out = ""
    end if
  end function json_escape

  function json_str(s) result(out)
    character(len=*), intent(in) :: s
    character(len=:), allocatable :: out
    out = '"' // json_escape(s) // '"'
  end function json_str

  !> The JSON record text for ONE diagnostic, from "  {" through
  !! the closing "  }," / "  }" line (each line NL-terminated).
  !! Separate subroutine for the same stack reason as
  !! diag_block_text: its concatenation temporaries are bounded by
  !! one record and released on return.
  subroutine json_record_text(diag, is_last, rec)
    type(diagnostic_t), intent(in) :: diag
    logical, intent(in) :: is_last
    character(len=:), allocatable, intent(out) :: rec
    character(len=*), parameter :: NL = achar(10)
    rec = "  {" // NL
    rec = rec // '    "code": ' // json_str(str_of(diag%code)) // &
          "," // NL
    rec = rec // '    "severity": ' // &
          json_str(str_of(diag%severity)) // "," // NL
    rec = rec // '    "message": ' // &
          json_str(str_of(diag%message)) // "," // NL
    if (diag%has_span) then
      rec = rec // '    "file": ' // &
            json_str(str_of(diag%span%source)) // "," // NL
      rec = rec // '    "line": ' // &
            trim(fmt_int(int(diag%span%line, int64))) // "," // NL
      rec = rec // '    "col": ' // &
            trim(fmt_int(int(diag%span%col, int64))) // "," // NL
      rec = rec // '    "span": {' // NL
      rec = rec // '      "source": ' // &
            json_str(str_of(diag%span%source)) // "," // NL
      rec = rec // '      "line": ' // &
            trim(fmt_int(int(diag%span%line, int64))) // "," // NL
      rec = rec // '      "col": ' // &
            trim(fmt_int(int(diag%span%col, int64))) // "," // NL
      rec = rec // '      "length": ' // &
            trim(fmt_int(int(diag%span%length, int64))) // NL
      rec = rec // "    }," // NL
    else
      rec = rec // '    "file": null,' // NL
      rec = rec // '    "line": null,' // NL
      rec = rec // '    "col": null,' // NL
      rec = rec // '    "span": null,' // NL
    end if
    rec = rec // '    "why": ' // json_str(str_of(diag%why)) // &
          "," // NL
    rec = rec // '    "help": ' // json_str(str_of(diag%help)) // NL
    if (is_last) then
      rec = rec // "  }" // NL
    else
      rec = rec // "  }," // NL
    end if
  end subroutine json_record_text

  !> ErrorBag.format_json(): json.dumps(records, indent=2) exactly.
  function error_bag_format_json(bag) result(out)
    type(error_bag_t), intent(in) :: bag
    character(len=:), allocatable :: out
    integer :: k, total, pos, lb
    type(str_box_t), allocatable :: recs(:)
    if (bag%n == 0) then
      out = "[]"
      return
    end if
    ! Per-record build + preallocated assembly, as in
    ! error_bag_format_text (the old loop self-concatenated `out`
    ! ~20 times per diagnostic and stack-overflowed the same way).
    allocate (recs(bag%n))
    total = 3  ! "[" + NL, plus the closing "]"
    do k = 1, bag%n
      call json_record_text(bag%diags(k), k == bag%n, recs(k)%s)
      total = total + len(recs(k)%s)
    end do
    allocate (character(len=total) :: out)
    out(1:1) = "["
    out(2:2) = achar(10)
    pos = 3
    do k = 1, bag%n
      lb = len(recs(k)%s)
      if (lb > 0) then
        out(pos:pos + lb - 1) = recs(k)%s
        pos = pos + lb
      end if
    end do
    out(pos:pos) = "]"
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
