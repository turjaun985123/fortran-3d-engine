! f3dc_lexer.f90 -- Lexer for the Forge3D `.f3d` language.
!
! Faithful Fortran port of tools/f3dc/lexer.py (see compiler/DESIGN.md).
! Python is the oracle: token kinds, lexemes, spans and diagnostics are
! mirrored one-for-one.
!
! Token kinds are plain strings in Python: WORD, NUMBER, STRING, COLOR,
! COMMA, COLON, NEWLINE and EOF.  Here they are an integer enum
! (TK_WORD .. TK_EOF); token_kind_name() maps an enum value back to the
! exact Python string.  A token's `text` is the raw lexeme exactly as
! written (a STRING keeps its quotes, a COLOR keeps its leading '#'),
! and its span is 1-based line/col/length plus the source name.
!
! Diagnostics are collected through the caller's error_bag (never
! raised for ordinary lexical errors, so lexing recovers and continues
! to the next character / line), with the same codes, messages, spans
! and help texts as lexer.py (its `hint` argument becomes the
! diagnostic's `help`, with `why` left empty, exactly as lexer.py's
! _make_diagnostic does when errors.py is present):
!
!   E101 -- unexpected / stray character.
!   E102 -- malformed number.
!   E103 -- unterminated string.
!   E820 -- security limit exceeded (input > 1 MiB, or a line longer
!           than 4096 characters).
!
! Interface coded against (f3dc_errors, per DESIGN.md / errors.py):
!   type(span_t)      :: source (allocatable char), line, col, length
!   type(error_bag_t) :: the diagnostic collection
!   error_bag_add(bag, diagnostic_t) builds the diagnostic
! bag_add is a free subroutine, NOT a type-bound procedure: this
! flang-new-18 build aborts ("not yet implemented: support for
! polymorphic types", CallInterface.cpp) on any type-bound procedure
! with a polymorphic passed-object dummy, so `bag%add(...)` cannot
! compile here at all.
! If that module is not present yet, compile-check against a stub with
! exactly this interface (stubs live in /tmp only, never committed).

module f3dc_lexer
  use, intrinsic :: iso_fortran_env, only: int64, real64
  use f3dc_errors, only: error_bag_t, span_t, diagnostic_t, error_bag_add
  implicit none
  private

  public :: token, token_list, tokenize, token_kind_name
  public :: TK_WORD, TK_NUMBER, TK_STRING, TK_COLOR
  public :: TK_COMMA, TK_COLON, TK_NEWLINE, TK_EOF
  public :: MAX_INPUT_BYTES, MAX_LINE_CHARS, MAX_TOKENS

  ! Token-kind enum (values are arbitrary; names are the contract).
  integer, parameter :: TK_WORD    = 1
  integer, parameter :: TK_NUMBER  = 2
  integer, parameter :: TK_STRING  = 3
  integer, parameter :: TK_COLOR   = 4
  integer, parameter :: TK_COMMA   = 5
  integer, parameter :: TK_COLON   = 6
  integer, parameter :: TK_NEWLINE = 7
  integer, parameter :: TK_EOF     = 8

  integer, parameter :: MAX_INPUT_BYTES = 1024 * 1024  ! 1 MiB
  integer, parameter :: MAX_LINE_CHARS  = 4096
  ! Phase 9 hardening cap: at most this many tokens per source file.
  ! Generous for any real scene (the 1 MiB input cap bounds a token
  ! to >= 1 byte, so pathological comma/newline floods are the only
  ! way to reach it); exceeding it, or a failed growth allocation,
  ! is reported as E820 (the existing security/limit code) instead
  ! of overflowing the doubling arithmetic or crashing on an
  ! unchecked allocate.
  integer, parameter :: MAX_TOKENS = 262144

  !> One token: mirrors Python Token(kind, text, span), plus parsed
  !! numeric values for NUMBER/COLOR tokens as a convenience for the
  !! parser (Python's lexer does not parse; these never change `text`).
  type :: token
    integer :: kind = TK_EOF
    character(len=:), allocatable :: text        ! raw lexeme
    character(len=:), allocatable :: source      ! span source name
    integer :: line = 1                          ! span line (1-based)
    integer :: col = 1                           ! span col  (1-based)
    integer :: length = 0                        ! span length
    integer(int64) :: int_value = 0_int64        ! NUMBER (int) / COLOR
    real(real64) :: real_value = 0.0_real64      ! NUMBER (decimal)
    logical :: has_int = .false.
    logical :: has_real = .false.
  end type token

  !> Result of tokenize(): a growable list of tokens, always ending in
  !! exactly one TK_EOF token.
  type :: token_list
    type(token), allocatable :: items(:)
    integer :: count = 0
  end type token_list

contains

  ! ------------------------------------------------------------------
  ! Public helpers
  ! ------------------------------------------------------------------

  !> The Python kind string for an enum value ("" for unknown values).
  function token_kind_name(kind) result(name)
    integer, intent(in) :: kind
    character(len=:), allocatable :: name
    select case (kind)
    case (TK_WORD);    name = "WORD"
    case (TK_NUMBER);  name = "NUMBER"
    case (TK_STRING);  name = "STRING"
    case (TK_COLOR);   name = "COLOR"
    case (TK_COMMA);   name = "COMMA"
    case (TK_COLON);   name = "COLON"
    case (TK_NEWLINE); name = "NEWLINE"
    case (TK_EOF);     name = "EOF"
    case default;      name = ""
    end select
  end function token_kind_name

  ! ------------------------------------------------------------------
  ! tokenize: port of lexer.tokenize(text, source_name, bag)
  ! ------------------------------------------------------------------
  subroutine tokenize(source_text, source_name, tokens, bag)
    character(len=*), intent(in) :: source_text
    character(len=*), intent(in) :: source_name
    type(token_list), intent(out) :: tokens
    type(error_bag_t), intent(inout) :: bag

    type(token), allocatable :: buf(:)
    integer :: n_tok, cap
    integer :: total_len, pos, line_no
    integer :: raw_start, raw_end, content_len, term_len, eff_len
    logical :: has_term, last_has_term
    integer :: last_raw_len
    integer :: eof_line, eof_col
    logical :: failed

    n_tok = 0
    cap = 0
    failed = .false.

    ! -- Security limit: input larger than 1 MiB (lexer.py: the bytes
    !    branch and the utf-8-encoded-length branch both report E820
    !    and return a lone EOF token).  Here source_text is a byte
    !    string, so its length is the byte count.
    if (len(source_text) > MAX_INPUT_BYTES) then
      call report(bag, "E820", source_name, 1, 1, 1, &
                  "input is larger than the 1 MiB limit", &
                  "split the scene into smaller files")
      call push_token(buf, n_tok, cap, &
                      make_token(TK_EOF, "", source_name, 1, 1, 0), &
                      bag, source_name, 1, failed)
      call finish(tokens, buf, n_tok, bag, source_name, failed)
      return
    end if

    total_len = len(source_text)
    line_no = 0
    last_raw_len = 0
    last_has_term = .false.

    ! -- Iterate lines exactly like text.splitlines(keepends=True):
    !    a line ends at \n, \r, \r\n, \v, \f or \x1c-\x1e; a trailing
    !    terminator does not produce an extra empty line.
    pos = 1
    do while (pos <= total_len)
      raw_start = pos
      raw_end = find_line_end(source_text, raw_start, total_len)
      line_no = line_no + 1
      last_raw_len = raw_end - raw_start + 1

      ! Separate the line terminator so spans/text stay accurate
      ! (lexer.py handles only \r\n, \n and \r here: a line split at
      ! \v/\f/\x1c-\x1e keeps that character inside `content`, where
      ! \v and \f are then skipped as whitespace).
      content_len = last_raw_len
      term_len = 0
      has_term = .false.
      if (last_raw_len >= 2) then
        if (source_text(raw_end-1:raw_end) == achar(13)//achar(10)) then
          content_len = last_raw_len - 2
          term_len = 2
          has_term = .true.
        end if
      end if
      if (.not. has_term .and. last_raw_len >= 1) then
        if (source_text(raw_end:raw_end) == achar(10) .or. &
            source_text(raw_end:raw_end) == achar(13)) then
          content_len = last_raw_len - 1
          term_len = 1
          has_term = .true.
        end if
      end if
      last_has_term = has_term

      ! Security limit: a line longer than 4096 characters is reported
      ! and truncated before lexing (lexer.py: content[:4096]).
      eff_len = content_len
      if (content_len > MAX_LINE_CHARS) then
        call report(bag, "E820", source_name, line_no, &
                    MAX_LINE_CHARS + 1, 1, &
                    "line is longer than the 4096 character limit", &
                    "split the statement across shorter lines")
        eff_len = MAX_LINE_CHARS
      end if

      call lex_line(source_text, raw_start, eff_len, line_no, &
                    source_name, buf, n_tok, cap, bag, failed)
      if (failed) then
        call finish(tokens, buf, n_tok, bag, source_name, failed)
        return
      end if

      ! NEWLINE token iff the raw line carried a \n / \r terminator;
      ! its text is always "\n" and its span length is the
      ! terminator's length (1 or 2), at col len(content)+1 where
      ! content is the (possibly truncated) line content.
      if (has_term) then
        call push_token(buf, n_tok, cap, &
                        make_token(TK_NEWLINE, achar(10), source_name, &
                                   line_no, eff_len + 1, term_len), &
                        bag, source_name, line_no, failed)
        if (failed) then
          call finish(tokens, buf, n_tok, bag, source_name, failed)
          return
        end if
      end if

      pos = raw_end + 1
    end do

    ! -- EOF: positioned just past the last character of the last
    !    line, or on the next line when the last line was terminated.
    if (line_no > 0) then
      if (last_has_term) then
        eof_line = line_no + 1
        eof_col = 1
      else
        eof_line = line_no
        ! lexer.py: len(last.rstrip("\r\n")) + 1; a last line not
        ! ending in \n or \r is untouched by rstrip, so its raw
        ! length is the content length.
        eof_col = last_raw_len + 1
      end if
    else
      eof_line = 1
      eof_col = 1
    end if
    call push_token(buf, n_tok, cap, &
                    make_token(TK_EOF, "", source_name, &
                               eof_line, eof_col, 0), &
                    bag, source_name, eof_line, failed)
    call finish(tokens, buf, n_tok, bag, source_name, failed)
  end subroutine tokenize

  ! ------------------------------------------------------------------
  ! One line's worth of tokens (the inner while loop of lexer.py).
  ! `base` is the 1-based offset of content(1) inside source_text;
  ! only the first `n` characters of content are lexed.
  ! ------------------------------------------------------------------
  subroutine lex_line(source_text, base, n, line_no, source_name, &
                      buf, n_tok, cap, bag, failed)
    character(len=*), intent(in) :: source_text, source_name
    integer, intent(in) :: base, n, line_no
    type(token), allocatable, intent(inout) :: buf(:)
    integer, intent(inout) :: n_tok, cap
    type(error_bag_t), intent(inout) :: bag
    logical, intent(inout) :: failed

    integer :: i, start, col, endpos, frac_start
    character(len=1) :: ch
    logical :: malformed, done, is_num_start
    character(len=:), allocatable :: lexeme

    i = 1
    done = .false.
    do while (i <= n .and. .not. done)
      ch = source_text(base+i-1:base+i-1)
      col = i  ! 1-based, same value as Python's i + 1

      ! Whitespace (spaces/tabs) separates tokens only.
      if (ch == " " .or. ch == achar(9) .or. &
          ch == achar(12) .or. ch == achar(11)) then
        i = i + 1
        cycle
      end if

      ! Comments: '//' to end of line.
      if (ch == "/" .and. i + 1 <= n) then
        if (source_text(base+i:base+i) == "/") then
          done = .true.
          exit
        end if
      end if

      ! '#' : COLOR literal, otherwise a comment to end of line.
      if (ch == "#") then
        if (is_color_at(source_text, base, i, n)) then
          call push_token(buf, n_tok, cap, &
                          make_token(TK_COLOR, &
                                     source_text(base+i-1:base+i+5), &
                                     source_name, line_no, col, 7), &
                          bag, source_name, line_no, failed)
          if (failed) return
          i = i + 7
          cycle
        end if
        done = .true.
        exit
      end if

      ! Commas are tokens in their own right (parser may skip).
      if (ch == ",") then
        call push_token(buf, n_tok, cap, &
                        make_token(TK_COMMA, ",", source_name, &
                                   line_no, col, 1), &
                        bag, source_name, line_no, failed)
        if (failed) return
        i = i + 1
        cycle
      end if

      ! Colons are tokens in their own right (parser may skip),
      ! e.g. 'texture: "path"' in property syntax.
      if (ch == ":") then
        call push_token(buf, n_tok, cap, &
                        make_token(TK_COLON, ":", source_name, &
                                   line_no, col, 1), &
                        bag, source_name, line_no, failed)
        if (failed) return
        i = i + 1
        cycle
      end if

      ! Double-quoted string, no escapes, cannot span lines.
      if (ch == '"') then
        endpos = find_char(source_text, base, i + 1, n, '"')
        if (endpos == 0) then
          lexeme = source_text(base+i-1:base+n-1)
          call report(bag, "E103", source_name, line_no, col, &
                      len(lexeme), &
                      "unterminated string: missing closing '""'", &
                      'add a closing " at the end of the string')
          call push_token(buf, n_tok, cap, &
                          make_token(TK_STRING, lexeme, source_name, &
                                     line_no, col, len(lexeme)), &
                          bag, source_name, line_no, failed)
          if (failed) return
          done = .true.
          exit
        end if
        lexeme = source_text(base+i-1:base+endpos-1)
        call push_token(buf, n_tok, cap, &
                        make_token(TK_STRING, lexeme, source_name, &
                                   line_no, col, len(lexeme)), &
                        bag, source_name, line_no, failed)
        if (failed) return
        i = endpos + 1
        cycle
      end if

      ! Number: optional '-', digits, optional decimal part.
      ! No exponent in v1 (P03 section 2).
      is_num_start = is_digit(ch)
      if (.not. is_num_start .and. ch == "-") then
        if (i + 1 <= n) is_num_start = &
            is_digit(source_text(base+i:base+i))
      end if
      if (is_num_start) then
        start = i
        if (source_text(base+i-1:base+i-1) == "-") i = i + 1
        do while (i <= n)
          if (.not. is_digit(source_text(base+i-1:base+i-1))) exit
          i = i + 1
        end do
        malformed = .false.
        if (i <= n) then
          if (source_text(base+i-1:base+i-1) == ".") then
            malformed = .true.  ! cleared if digits follow
            i = i + 1
            frac_start = i
            do while (i <= n)
              if (.not. is_digit(source_text(base+i-1:base+i-1))) exit
              i = i + 1
            end do
            if (i > frac_start) malformed = .false.
            ! A second '.' (e.g. 1.2.3) is malformed.
            if (i <= n) then
              if (source_text(base+i-1:base+i-1) == ".") then
                malformed = .true.
                i = i + 1
                do while (i <= n)
                  if (.not. is_digit(source_text(base+i-1:base+i-1)) &
                      .and. source_text(base+i-1:base+i-1) /= ".") exit
                  i = i + 1
                end do
              end if
            end if
          end if
        end if
        if (i <= n) then
          ch = source_text(base+i-1:base+i-1)
          if (is_alpha(ch) .or. ch == "_") then
            ! '640x480': 'x' joins two numbers in the parser, so it
            ! starts a separate WORD token, not an error.
            if (ch /= "x" .and. ch /= "X") then
              malformed = .true.
              do while (i <= n)
                if (.not. is_word_char( &
                        source_text(base+i-1:base+i-1))) exit
                i = i + 1
              end do
            end if
          end if
        end if
        lexeme = source_text(base+start-1:base+i-2)
        if (malformed) then
          call report(bag, "E102", source_name, line_no, start, &
                      len(lexeme), &
                      "malformed number '"//lexeme//"'", &
                      "write a number like 2, -1.5 or 0.25 " // &
                      "(no exponent)")
        end if
        call push_token(buf, n_tok, cap, &
                        make_token(TK_NUMBER, lexeme, source_name, &
                                   line_no, start, len(lexeme)), &
                        bag, source_name, line_no, failed)
        if (failed) return
        cycle
      end if

      ! Word: letter/'_' then letters/digits/'_'/'-'.
      if (is_word_start(ch)) then
        start = i
        i = i + 1
        do while (i <= n)
          if (.not. is_word_char(source_text(base+i-1:base+i-1))) exit
          i = i + 1
        end do
        lexeme = source_text(base+start-1:base+i-2)
        call push_token(buf, n_tok, cap, &
                        make_token(TK_WORD, lexeme, source_name, &
                                   line_no, start, len(lexeme)), &
                        bag, source_name, line_no, failed)
        if (failed) return
        cycle
      end if

      ! Anything else is a stray character: report and skip it.
      call report(bag, "E101", source_name, line_no, col, 1, &
                  "unexpected character '"//ch//"'", &
                  "remove this character")
      i = i + 1
    end do
  end subroutine lex_line

  ! ------------------------------------------------------------------
  ! Internal helpers
  ! ------------------------------------------------------------------

  ! Report one diagnostic through the bag, mirroring lexer.py's
  ! _report/_make_diagnostic with errors.py present: severity is
  ! always "error", why is "" and help is the Python `hint`.
  subroutine report(bag, code, source_name, line, col, length, &
                    message, hint)
    type(error_bag_t), intent(inout) :: bag
    character(len=*), intent(in) :: code, source_name, message, hint
    integer, intent(in) :: line, col, length
    type(diagnostic_t) :: diag
    diag%code = code
    diag%severity = "error"
    diag%message = message
    diag%has_span = .true.
    diag%span%source = source_name
    diag%span%line = line
    diag%span%col = col
    diag%span%length = length
    diag%why = ""
    diag%help = hint
    call error_bag_add(bag, diag)
  end subroutine report

  ! Build a token, filling the parsed numeric values for NUMBER and
  ! COLOR tokens (best-effort: unparseable lexemes keep the flags
  ! false, matching that Python's lexer never parses at all).
  function make_token(kind, text, source_name, line, col, length) &
      result(tok)
    integer, intent(in) :: kind, line, col, length
    character(len=*), intent(in) :: text, source_name
    type(token) :: tok
    integer :: ios, k, digit
    tok%kind = kind
    tok%text = text
    tok%source = source_name
    tok%line = line
    tok%col = col
    tok%length = length
    select case (kind)
    case (TK_NUMBER)
      if (index(text, ".") > 0) then
        read (text, *, iostat=ios) tok%real_value
        if (ios == 0) tok%has_real = .true.
      else
        read (text, *, iostat=ios) tok%int_value
        if (ios == 0) then
          tok%has_int = .true.
          tok%real_value = real(tok%int_value, real64)
          tok%has_real = .true.
        else
          read (text, *, iostat=ios) tok%real_value
          if (ios == 0) tok%has_real = .true.
        end if
      end if
    case (TK_COLOR)
      ! text is "#RRGGBB": int_value is the 0xRRGGBB value.
      ! Bounds guard (Phase 9): never index past a short lexeme;
      ! lex_line only builds COLOR from a verified 7-char span, but
      ! a future/short caller must not read out of bounds.
      tok%int_value = 0_int64
      if (len(text) >= 7) then
        do k = 2, 7
          digit = hex_value(text(k:k))
          if (digit < 0) exit
          tok%int_value = tok%int_value * 16_int64 + digit
          if (k == 7) tok%has_int = .true.
        end do
      end if
    end select
  end function make_token

  ! Append `tok` to the growable buffer (amortised doubling).
  ! Phase 9 hardening: the doubling is capped at MAX_TOKENS, so
  ! 2 * cap can never overflow (cap <= MAX_TOKENS at all times),
  ! and the growth allocate carries stat=.  On the cap or on an
  ! allocation failure an E820 diagnostic is reported, `failed` is
  ! set, the token is dropped and the caller abandons lexing and
  ! finishes with the tokens gathered so far -- instead of the
  ! previous runtime abort on a failed unchecked allocate.
  subroutine push_token(buf, n_tok, cap, tok, bag, source_name, &
                        line, failed)
    type(token), allocatable, intent(inout) :: buf(:)
    integer, intent(inout) :: n_tok, cap
    type(token), intent(in) :: tok
    type(error_bag_t), intent(inout) :: bag
    character(len=*), intent(in) :: source_name
    integer, intent(in) :: line
    logical, intent(inout) :: failed
    type(token), allocatable :: tmp(:)
    integer :: k, newcap, st
    if (failed) return
    if (n_tok >= MAX_TOKENS) then
      call report(bag, "E820", source_name, line, 1, 1, &
                  "too many tokens (limit 262144)", &
                  "split the scene into smaller files")
      failed = .true.
      return
    end if
    if (n_tok >= cap) then
      newcap = min(MAX_TOKENS, max(16, 2 * cap))
      allocate (tmp(newcap), stat=st)
      if (st /= 0) then
        call report(bag, "E820", source_name, line, 1, 1, &
                    "out of memory while storing tokens", &
                    "split the scene into smaller files")
        failed = .true.
        return
      end if
      do k = 1, n_tok
        tmp(k) = buf(k)
      end do
      call move_alloc(tmp, buf)
      cap = size(buf)
    end if
    n_tok = n_tok + 1
    buf(n_tok) = tok
  end subroutine push_token

  ! Move the first n_tok entries of buf into the token_list result.
  ! Phase 9 hardening: the result allocate carries stat=; on
  ! failure an E820 is reported and an empty (but allocated) list
  ! is returned, so callers indexing 1..count stay in bounds.
  subroutine finish(tokens, buf, n_tok, bag, source_name, failed)
    type(token_list), intent(out) :: tokens
    type(token), allocatable, intent(inout) :: buf(:)
    integer, intent(in) :: n_tok
    type(error_bag_t), intent(inout) :: bag
    character(len=*), intent(in) :: source_name
    logical, intent(inout) :: failed
    integer :: k, st
    allocate (tokens%items(n_tok), stat=st)
    if (st /= 0) then
      call report(bag, "E820", source_name, 1, 1, 1, &
                  "out of memory while storing tokens", &
                  "split the scene into smaller files")
      failed = .true.
      allocate (tokens%items(0), stat=st)
      tokens%count = 0
      if (allocated(buf)) deallocate (buf)
      return
    end if
    do k = 1, n_tok
      tokens%items(k) = buf(k)
    end do
    tokens%count = n_tok
    if (allocated(buf)) deallocate (buf)
  end subroutine finish

  ! End index (1-based, into text) of the line starting at `start`:
  ! the position of its line-break character (\r\n counts as one
  ! break ending on the \n), or total_len for an unterminated line.
  function find_line_end(text, start, total_len) result(e)
    character(len=*), intent(in) :: text
    integer, intent(in) :: start, total_len
    integer :: e, j
    e = total_len
    do j = start, total_len
      if (is_line_break(text(j:j))) then
        e = j
        if (text(j:j) == achar(13) .and. j + 1 <= total_len) then
          if (text(j+1:j+1) == achar(10)) e = j + 1
        end if
        return
      end if
    end do
  end function find_line_end

  ! Python str.splitlines() break characters (single-byte subset):
  ! \n \v \f \r \x1c \x1d \x1e.  (\x85 and \u2028/\u2029 are Unicode
  ! code points and cannot be matched on a byte string; see report.)
  pure logical function is_line_break(ch)
    character(len=1), intent(in) :: ch
    integer :: c
    c = iachar(ch)
    is_line_break = (c == 10 .or. c == 11 .or. c == 12 .or. c == 13 &
                     .or. c == 28 .or. c == 29 .or. c == 30)
  end function is_line_break

  ! Index (content-relative, 1-based) of the first occurrence of
  ! `target` at or after content position `from`, or 0 if absent.
  ! Mirrors str.find on the line content.
  function find_char(text, base, from, n, target) result(p)
    character(len=*), intent(in) :: text
    integer, intent(in) :: base, from, n
    character(len=1), intent(in) :: target
    integer :: p, j
    p = 0
    do j = from, n
      if (text(base+j-1:base+j-1) == target) then
        p = j
        return
      end if
    end do
  end function find_char

  ! True iff content[i:] is '#' + exactly 6 hex digits + word boundary
  ! (port of lexer._is_color_at; indices are content-relative).
  logical function is_color_at(text, base, i, n)
    character(len=*), intent(in) :: text
    integer, intent(in) :: base, i, n
    integer :: k
    is_color_at = .false.
    if (i + 6 > n) return  ! need '#' plus six digits within the line
    do k = i + 1, i + 6
      if (hex_value(text(base+k-1:base+k-1)) < 0) return
    end do
    ! Exactly six: a seventh word character (hex digit, letter,
    ! digit, '_' or '-') means this is not a #RRGGBB literal.
    if (i + 7 <= n) then
      if (is_word_char(text(base+i+6:base+i+6))) return
    end if
    is_color_at = .true.
  end function is_color_at

  ! Hex digit value, or -1 (ASCII subset of Python's _HEX set).
  pure integer function hex_value(ch)
    character(len=1), intent(in) :: ch
    integer :: c
    c = iachar(ch)
    if (c >= iachar("0") .and. c <= iachar("9")) then
      hex_value = c - iachar("0")
    else if (c >= iachar("a") .and. c <= iachar("f")) then
      hex_value = c - iachar("a") + 10
    else if (c >= iachar("A") .and. c <= iachar("F")) then
      hex_value = c - iachar("A") + 10
    else
      hex_value = -1
    end if
  end function hex_value

  ! ASCII subsets of Python's str.isalpha()/isdigit()/isalnum(); the
  ! Python predicates are Unicode-aware (see the port report).
  pure logical function is_alpha(ch)
    character(len=1), intent(in) :: ch
    integer :: c
    c = iachar(ch)
    is_alpha = (c >= iachar("a") .and. c <= iachar("z")) .or. &
               (c >= iachar("A") .and. c <= iachar("Z"))
  end function is_alpha

  pure logical function is_digit(ch)
    character(len=1), intent(in) :: ch
    integer :: c
    c = iachar(ch)
    is_digit = (c >= iachar("0") .and. c <= iachar("9"))
  end function is_digit

  ! Port of lexer._is_word_start: ch.isalpha() or ch == "_".
  pure logical function is_word_start(ch)
    character(len=1), intent(in) :: ch
    is_word_start = is_alpha(ch) .or. ch == "_"
  end function is_word_start

  ! Port of lexer._is_word_char: ch.isalnum() or ch in "_-".
  pure logical function is_word_char(ch)
    character(len=1), intent(in) :: ch
    is_word_char = is_alpha(ch) .or. is_digit(ch) .or. &
                   ch == "_" .or. ch == "-"
  end function is_word_char

end module f3dc_lexer
