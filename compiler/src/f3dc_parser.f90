! f3dc_parser -- Forge3D .f3d parser: AST construction (dyn dicts).
!
! Faithful Fortran port of tools/f3dc/ast_nodes.py + tools/f3dc/parser.py
! (B04 + B05).  Python is the oracle; this module mirrors it function by
! function, including every statement form, every alias field the Python
! _make() sets, and every parse diagnostic (same codes, messages, spans
! and did-you-mean behaviour).
!
! ---------------------------------------------------------------------
! Entry point (mirrors Python  parse(text, source_name, bag) -> Program)
!
!   subroutine f3dc_parse(text, source_name, bag, program)
!     character(*), intent(in)    :: text, source_name
!     type(error_bag_t), intent(inout) :: bag
!     type(dyn), intent(out)      :: program   ! the Program node (dyn dict)
!
! Like the Python Parser, f3dc_parse tokenises internally (via
! f3dc_lexer.tokenize) and groups tokens into lines.  Diagnostics are
! appended to bag AND mirrored into the Program node's "errors" field,
! exactly as Python's Parser.errors list.
!
! Typed-AST entry point (Phase 6 / C1, purely additive):
!
!   subroutine parse_program_ast(text, source_name, bag, ast, ok)
!     character(*), intent(in)    :: text, source_name
!     type(error_bag_t), intent(inout) :: bag
!     type(ast_program), intent(out)   :: ast  ! from f3dc_ast
!     logical, intent(out)        :: ok
!
! parse_program_ast runs f3dc_parse unchanged to the dyn Program node
! and converts that node via f3dc_ast's ast_program_from_dyn.  ok is
! .true. only when the parse recorded no error: the Program node's
! "errors" list is empty and bag holds no error diagnostic.  On a
! failed parse ast still holds the converted (partial) program, so
! callers may inspect it, but must check ok before trusting it.
!
! ---------------------------------------------------------------------
! AST representation (per compiler/DESIGN.md): every node is a dyn DICT
! whose keys are exactly the Python node's __dict__ keys, in Python
! insertion order: dataclass fields first (ast_nodes.py declaration
! order, defaults where _make() does not pass them), then every extra
! field _make() sets, in call order.  Tuples (vec3, size, rgb) become
! dyn lists; None becomes dyn_null; "span" is always dyn_null (the
! Python parser passes span=None everywhere); "line" is the 1-based
! source line.  Notable oracle quirks preserved on purpose:
!   * GroupStmt "body" stays an EMPTY list (Python passes children=,
!     never body=, so the dataclass default survives).
!   * CameraStmt "pos" stays null (Python passes at=/position=).
!   * ControlsStmt "kind" stays "orbit" (Python passes mode=/type=).
!   * RepeatStmt "a" stays 0 and "b" stays null (Python passes count=).
!
! ---------------------------------------------------------------------
! Sibling interfaces (compiler/DESIGN.md contract; all lexer/bag
! contact is isolated in build_lines / report_to_bag):
!   f3dc_dyn:    type dyn (components kind/i/r/s + list/dict payload);
!                kind tags DYN_K_NULL=0 .. DYN_K_DICT=6; constructors
!                dyn_null/dyn_bool/dyn_int/dyn_real/dyn_str/dyn_list/
!                dyn_dict; dyn_copy, dyn_list_push, dyn_list_len,
!                dyn_list_at, dyn_dict_set (Python dict semantics:
!                replacing a key keeps its position), dyn_dict_get
!                (dyn_null when absent), dyn_dict_has, dyn_dict_len,
!                dyn_dict_key_at (function).
!   f3dc_errors: type error_bag_t; error_bag_add(bag, diagnostic_t)
!                with make_diagnostic_span / make_span; did_you_mean
!                (word, char_list, result, found).
!   f3dc_str:    char_list + char_list_append (for did_you_mean).
!   f3dc_lexer:  type token (kind, text, line, col, int_value,
!                real_value), type token_list (items, count);
!                kind constants TK_WORD .. TK_EOF (no PUNCT kind:
!                stray characters are E101-skipped, as in lexer.py);
!                tokenize(source_text, source_name, tokens, bag).
! NOTE: f3dc_lexer as landed imports `error_bag`/`bag_add` from
! f3dc_errors, names that module does not export (it exports
! error_bag_t / error_bag_add), so the lexer does not yet compile
! against f3dc_errors; this module follows the f3dc_errors names
! (error_bag_t) throughout, and tokenize is called with that bag --
! the one call site is in build_lines.
module f3dc_parser
  use iso_fortran_env, only: int64, real64
  use f3dc_dyn, only: dyn, dyn_null, dyn_bool, dyn_int, dyn_real, &
                      dyn_str, dyn_list, dyn_dict, dyn_copy, dyn_assign, &
                      dyn_list_push, dyn_list_len, dyn_list_at, &
                      dyn_dict_set, dyn_dict_get, dyn_dict_has, &
                      dyn_dict_len, dyn_dict_key_at, &
                      DYN_K_NULL, DYN_K_BOOL, DYN_K_INT, DYN_K_REAL, &
                      DYN_K_STR, DYN_K_LIST, DYN_K_DICT
  use f3dc_errors, only: error_bag_t, make_span, &
                         make_diagnostic_span, error_bag_add, &
                         error_bag_has_errors, &
                         err_did_you_mean => did_you_mean
  use f3dc_str, only: char_list, char_list_append, str_builder, &
                      sb_init, sb_add, sb_text
  use f3dc_lexer, only: token, token_list, tokenize, TK_WORD, &
                        TK_NUMBER, TK_STRING, TK_COLOR, TK_COMMA, &
                        TK_COLON, TK_NEWLINE, TK_EOF
  use f3dc_ast, only: ast_program, ast_stmt, ast_program_from_dyn, &
                      ast_program_to_dyn
  implicit none
  private
  public :: f3dc_parse
  public :: parse_program_ast

  ! Internal token kinds (mirror the Python kind strings).
  integer, parameter :: K_WORD = 1, K_NUMBER = 2, K_STRING = 3, &
                        K_COLOR = 4, K_COMMA = 5, K_COLON = 6, &
                        K_NEWLINE = 7, K_EOF = 8, K_PUNCT = 9, &
                        K_OTHER = 10

  type :: itok
    integer :: kind = K_EOF
    character(:), allocatable :: text   ! STRING texts are unquoted
    integer :: line = 0
    integer :: col = 0
  end type itok

  type :: line_rec
    integer :: no = 0
    type(itok), allocatable :: toks(:)
  end type line_rec

  ! Per-line cursor (Python _Line).
  type :: line_cur
    type(itok), allocatable :: toks(:)
    integer :: i = 1                    ! next token (1-based)
    integer :: no = 0
  end type line_cur

  type :: err_rec
    character(:), allocatable :: code, msg
    integer :: line = 0, col = 0
  end type err_rec

  ! Parser state (Python Parser + the _LineError exception channel:
  ! le_set/le_code/le_msg carry a raised line error to the handler).
  type :: parser_state
    character(:), allocatable :: source
    type(error_bag_t), pointer :: bag => null()
    type(err_rec), allocatable :: errs(:)
    integer :: syntax_errors = 0
    logical :: stopped = .false.
    logical :: le_set = .false.
    character(:), allocatable :: le_code, le_msg
  end type parser_state

  ! Duplicate-property tracker (Python `seen` set of short words).
  type :: str_set
    integer :: n = 0
    character(32) :: items(64)
  end type str_set

  ! ------------------------------------------------------------------
  ! Vocabulary (parser.py module constants, same order where it matters)
  ! ------------------------------------------------------------------
  character(16), parameter :: PRIMS(18) = [character(16) :: &
    "cube", "sphere", "cylinder", "plane", "pyramid", "cone", "torus", &
    "circle", "ring", "capsule", "tube", "lathe", "extrude", &
    "icosahedron", "octahedron", "tetrahedron", "dodecahedron", &
    "torusknot"]
  character(16), parameter :: ANIM_VERBS(7) = [character(16) :: &
    "spin", "bob", "pulse", "orbit", "move", "turn", "grow"]
  character(16), parameter :: RESERVED_ALL(7) = [character(16) :: &
    "let", "if", "for", "function", "system", "eval", "import"]
  character(16), parameter :: RESERVED_SEC(3) = [character(16) :: &
    "system", "eval", "import"]
  ! STARTERS: did-you-mean candidates, in Python order (ring appears
  ! twice there too: once in the starter tuple, once in PRIMS).
  character(16), parameter :: STARTERS(45) = [character(16) :: &
    "scene", "camera", "light", "group", "end", "animate", "load", &
    "import", "repeat", "grid", "ring", "controls", "render", "export", &
    "filter", "instance", "shader", "morph", "bone", "skin", &
    "cube", "sphere", "cylinder", "plane", "pyramid", "cone", "torus", &
    "circle", "ring", "capsule", "tube", "lathe", "extrude", &
    "icosahedron", "octahedron", "tetrahedron", "dodecahedron", &
    "torusknot", &
    "spin", "bob", "pulse", "orbit", "move", "turn", "grow"]
  character(16), parameter :: COLOUR_WORDS(48) = [character(16) :: &
    "red", "green", "blue", "yellow", "magenta", "cyan", "orange", &
    "purple", "pink", "white", "black", "gray", "grey", "gold", &
    "silver", "brown", "beige", "coral", "crimson", "indigo", &
    "ivory", "khaki", "lavender", "lime", "maroon", "navy", "olive", &
    "teal", "turquoise", "violet", "salmon", "tan", "skyblue", &
    "steelblue", "seagreen", "forestgreen", "darkred", "darkblue", &
    "darkgreen", "lightblue", "lightgreen", "hotpink", "deeppink", &
    "aqua", "azure", "fuchsia", "limegreen", "royalblue"]
  character(16), parameter :: OBJECT_PROP_WORDS(36) = [character(16) :: &
    "at", "pos", "position", "size", "radius", "height", "width", &
    "depth", "rotate", "rot", "scale", "material", "segments", &
    "detail", "capped", "open", "texture", "colour", "color", &
    "named", "name", "shader", "inner", "outer", "tube", &
    "tube_segments", "extrude_depth", "path", "points", "shape", &
    "shading", "mirror", "normalmap", "mr", "emissivemap", &
    "occlusionmap"]
  character(16), parameter :: ANIM_PROP_WORDS(10) = [character(16) :: &
    "axis", "speed", "duration", "fps", "ease", "loop", "amplitude", &
    "distance", "amount", "angle"]
  character(16), parameter :: AXES(3) = [character(16) :: "x", "y", "z"]
  character(16), parameter :: LOOP_WORDS(3) = [character(16) :: &
    "once", "forever", "pingpong"]
  character(16), parameter :: SCENE_CLAUSES(11) = [character(16) :: &
    "size", "bg", "background", "colour", "color", "fog", "tonemap", &
    "tone", "shadow", "shading", "antialias"]

contains

  ! ==================================================================
  ! Small string helpers
  ! ==================================================================

  ! Python str.lower() (ASCII range; see report for the Unicode note).
  function str_lower(s) result(r)
    character(*), intent(in) :: s
    character(:), allocatable :: r
    integer :: i, c
    allocate(character(len(s)) :: r)
    do i = 1, len(s)
      c = iachar(s(i:i))
      if (c >= iachar('A') .and. c <= iachar('Z')) then
        r(i:i) = achar(c + 32)
      else
        r(i:i) = s(i:i)
      end if
    end do
  end function str_lower

  ! Python str.rstrip(":") -- strip ALL trailing ':' characters.
  function rstrip_colon(s) result(r)
    character(*), intent(in) :: s
    character(:), allocatable :: r
    integer :: n
    n = len(s)
    do while (n > 0)
      if (s(n:n) /= ':') exit
      n = n - 1
    end do
    r = s(1:n)
  end function rstrip_colon

  ! The normalised word form used by peek_word()/statement dispatch:
  ! lower().rstrip(":").
  function word_norm(s) result(r)
    character(*), intent(in) :: s
    character(:), allocatable :: r
    r = rstrip_colon(str_lower(s))
  end function word_norm

  function itoa(v) result(r)
    integer(int64), intent(in) :: v
    character(:), allocatable :: r
    character(24) :: buf
    write(buf, '(I0)') v
    r = trim(buf)
  end function itoa

  logical function in_list(word, arr)
    character(*), intent(in) :: word
    character(16), intent(in) :: arr(:)
    integer :: i
    in_list = .false.
    do i = 1, size(arr)
      if (trim(arr(i)) == word) then
        in_list = .true.
        return
      end if
    end do
  end function in_list

  logical function set_has(seen, key)
    type(str_set), intent(in) :: seen
    character(*), intent(in) :: key
    integer :: i
    set_has = .false.
    do i = 1, seen%n
      if (trim(seen%items(i)) == key) then
        set_has = .true.
        return
      end if
    end do
  end function set_has

  subroutine set_add(seen, key)
    type(str_set), intent(inout) :: seen
    character(*), intent(in) :: key
    if (set_has(seen, key)) return
    if (seen%n < size(seen%items)) then
      seen%n = seen%n + 1
      seen%items(seen%n) = key
    end if
  end subroutine set_add

  ! ==================================================================
  ! did-you-mean: errors.py did_you_mean (true Damerau-Levenshtein)
  ! with parser.py's local restricted-DL fallback, mirroring
  ! parser._did_you_mean's control flow exactly.
  ! ==================================================================

  ! parser.py _dl: restricted (optimal-string-alignment) DL, limit 2.
  function dl_osa(a, b) result(dist)
    character(*), intent(in) :: a, b
    integer :: dist
    integer, parameter :: LIMIT = 2
    integer :: la, lb, i, j, cost
    integer, allocatable :: d(:, :)
    la = len(a); lb = len(b)
    if (abs(la - lb) > LIMIT) then; dist = LIMIT + 1; return; end if
    allocate(d(0:la, 0:lb))
    do i = 0, la
      d(i, 0) = i
    end do
    do j = 0, lb
      d(0, j) = j
    end do
    do i = 1, la
      do j = 1, lb
        cost = 1
        if (a(i:i) == b(j:j)) cost = 0
        d(i, j) = min(d(i - 1, j) + 1, d(i, j - 1) + 1, &
                      d(i - 1, j - 1) + cost)
        if (i > 1) then
          if (j > 1) then
            if (a(i:i) == b(j - 1:j - 1) &
                .and. a(i - 1:i - 1) == b(j:j)) then
              d(i, j) = min(d(i, j), d(i - 2, j - 2) + 1)
            end if
          end if
        end if
      end do
    end do
    dist = d(la, lb)
    deallocate(d)
  end function dl_osa

  ! parser._did_you_mean: errors.did_you_mean first (the real
  ! f3dc_errors subroutine, true Damerau-Levenshtein); when it finds
  ! nothing, parser.py's local restricted-DL fallback runs.
  subroutine did_you_mean(word, cands, sugg, found)
    character(*), intent(in) :: word
    character(16), intent(in) :: cands(:)
    character(:), allocatable, intent(out) :: sugg
    logical, intent(out) :: found
    type(char_list) :: cl
    character(:), allocatable :: lw, lc
    integer :: k, dist, bestd
    found = .false.
    sugg = ""
    if (len(word) == 0) return
    do k = 1, size(cands)
      call char_list_append(cl, trim(cands(k)))
    end do
    call err_did_you_mean(word, cl, sugg, found)
    if (found) return
    ! parser.py local fallback over its restricted _dl.
    lw = str_lower(word)
    bestd = 3
    do k = 1, size(cands)
      lc = str_lower(trim(cands(k)))
      dist = dl_osa(lw, lc)
      if (dist < bestd) then
        bestd = dist
        sugg = trim(cands(k))
        found = .true.
      end if
    end do
  end subroutine did_you_mean

  ! ==================================================================
  ! dyn helpers
  ! ==================================================================

  subroutine dset(d, key, val)
    type(dyn), intent(inout) :: d
    character(*), intent(in) :: key
    type(dyn), intent(in) :: val
    call dyn_dict_set(d, key, val)
  end subroutine dset

  function dget(d, key) result(v)
    type(dyn), intent(in) :: d
    character(*), intent(in) :: key
    type(dyn) :: v
    v = dyn_dict_get(d, key)
  end function dget

  ! Python int(x): truncation toward zero for reals.
  function dyn_to_int(d) result(v)
    type(dyn), intent(in) :: d
    integer(int64) :: v
    if (d%kind == DYN_K_INT) then
      v = d%i
    else if (d%kind == DYN_K_REAL) then
      v = int(d%r, int64)
    else
      v = 0_int64
    end if
  end function dyn_to_int

  ! Unary minus preserving the Python int/float distinction.
  function dyn_neg(d) result(v)
    type(dyn), intent(in) :: d
    type(dyn) :: v
    if (d%kind == DYN_K_INT) then
      v = dyn_int(-d%i)
    else if (d%kind == DYN_K_REAL) then
      v = dyn_real(-d%r)
    else
      v = dyn_null()
    end if
  end function dyn_neg

  function vec3_of(a, b, c) result(v)
    type(dyn), intent(in) :: a, b, c
    type(dyn) :: v
    v = dyn_list()
    call dyn_list_push(v, a)
    call dyn_list_push(v, b)
    call dyn_list_push(v, c)
  end function vec3_of

  function pair_of(a, b) result(v)
    integer(int64), intent(in) :: a, b
    type(dyn) :: v
    v = dyn_list()
    call dyn_list_push(v, dyn_int(a))
    call dyn_list_push(v, dyn_int(b))
  end function pair_of

  ! ast_nodes.colour_raw + parser._colour_raw_str: canonical raw
  ! colour string (named/hex lower-cased, spaces removed; rgb tuple
  ! rendered as rgb(r,g,b)); null stays null.
  function colour_raw_str(colour, has_colour) result(v)
    type(dyn), intent(in) :: colour
    logical, intent(in) :: has_colour
    type(dyn) :: v
    character(:), allocatable :: s, t
    integer :: i
    if (.not. has_colour) then
      v = dyn_null()
      return
    end if
    if (colour%kind == DYN_K_LIST) then
      if (dyn_list_len(colour) == 3) then
        s = "rgb(" // itoa(dyn_to_int(dyn_list_at(colour, 1))) // "," &
            // itoa(dyn_to_int(dyn_list_at(colour, 2))) // "," &
            // itoa(dyn_to_int(dyn_list_at(colour, 3))) // ")"
        v = dyn_str(s)
        return
      end if
      v = dyn_str("")
      return
    end if
    if (colour%kind == DYN_K_STR) then
      t = str_lower(colour%s)
      allocate(character(len(t)) :: s)
      block
        integer :: m
        m = 0
        do i = 1, len(t)
          if (t(i:i) /= ' ') then
            m = m + 1
            s(m:m) = t(i:i)
          end if
        end do
        s = s(1:m)
      end block
      v = dyn_str(s)
      return
    end if
    v = dyn_null()
  end function colour_raw_str

  ! ==================================================================
  ! parser._num: int(s) if possible, else float(s) with the
  ! "-?\d+\.0+$ -> int" rule, else None (ok = .false.).
  ! ==================================================================

  ! Matches ^-?\d+$ (Python int() also accepts '+' and underscores;
  ! lexer NUMBER lexemes never contain those -- see report).
  logical function is_int_text(s)
    character(*), intent(in) :: s
    integer :: i, n
    n = len(s)
    is_int_text = .false.
    if (n == 0) return
    i = 1
    if (s(1:1) == '-') i = 2
    if (i > n) return
    do while (i <= n)
      if (s(i:i) < '0' .or. s(i:i) > '9') return
      i = i + 1
    end do
    is_int_text = .true.
  end function is_int_text

  ! Matches ^-?\d+\.0+$ (the int-valued float spelling).
  logical function is_zero_frac_text(s)
    character(*), intent(in) :: s
    integer :: i, n
    n = len(s)
    is_zero_frac_text = .false.
    i = 1
    if (i <= n) then
      if (s(1:1) == '-') i = 2
    end if
    if (i > n) return
    if (s(i:i) < '0' .or. s(i:i) > '9') return
    do while (i <= n)
      if (s(i:i) < '0' .or. s(i:i) > '9') exit
      i = i + 1
    end do
    if (i > n) return
    if (s(i:i) /= '.') return
    i = i + 1
    if (i > n) return
    do while (i <= n)
      if (s(i:i) /= '0') return
      i = i + 1
    end do
    is_zero_frac_text = .true.
  end function is_zero_frac_text

  ! What Python float(s) accepts over the lexer lexeme alphabet:
  ! optional '-', digits with at most one '.', at least one digit.
  logical function is_real_text(s)
    character(*), intent(in) :: s
    integer :: i, n, ndig, ndot
    n = len(s)
    is_real_text = .false.
    if (n == 0) return
    i = 1
    if (s(1:1) == '-') i = 2
    ndig = 0; ndot = 0
    do while (i <= n)
      if (s(i:i) >= '0' .and. s(i:i) <= '9') then
        ndig = ndig + 1
      else if (s(i:i) == '.') then
        ndot = ndot + 1
        if (ndot > 1) return
      else
        return
      end if
      i = i + 1
    end do
    is_real_text = ndig >= 1
  end function is_real_text

  subroutine parse_num(text, val, ok)
    character(*), intent(in) :: text
    type(dyn), intent(out) :: val
    logical, intent(out) :: ok
    integer(int64) :: iv
    real(real64) :: rv
    integer :: ios
    ok = .false.
    val = dyn_null()
    if (is_int_text(text)) then
      read(text, *, iostat=ios) iv
      if (ios == 0) then
        val = dyn_int(iv)
        ok = .true.
        return
      end if
      ! int64 overflow: Python would keep an arbitrary-precision int;
      ! fall through to a real (documented divergence, absurd inputs).
    end if
    if (.not. is_real_text(text)) return
    read(text, *, iostat=ios) rv
    if (ios /= 0) return
    if (rv == real(int(rv, int64), real64) &
        .and. abs(rv) < 9.0e18_real64 &
        .and. is_zero_frac_text(text)) then
      val = dyn_int(int(rv, int64))
    else
      val = dyn_real(rv)
    end if
    ok = .true.
  end subroutine parse_num

  ! ==================================================================
  ! Regex-equivalent matchers (the parser's re.match calls)
  ! ==================================================================

  ! ^(\d+)x(\d+)$  (case-sensitive 'x', as in parser.size/peek_size_token)
  logical function match_size_tok(s, a, b)
    character(*), intent(in) :: s
    integer(int64), intent(out) :: a, b
    integer :: i, n, xpos
    match_size_tok = .false.
    a = 0; b = 0
    n = len(s)
    xpos = 0
    do i = 1, n
      if (s(i:i) == 'x') then
        if (xpos /= 0) return
        xpos = i
      else if (s(i:i) < '0' .or. s(i:i) > '9') then
        return
      end if
    end do
    if (xpos <= 1 .or. xpos >= n) return
    call digits_to_int(s(1:xpos - 1), a)
    call digits_to_int(s(xpos + 1:n), b)
    match_size_tok = .true.
  end function match_size_tok

  ! ^x(\d+)$ with re.I (the 'x' is case-insensitive here)
  logical function match_xdigits(s, b)
    character(*), intent(in) :: s
    integer(int64), intent(out) :: b
    integer :: i, n
    match_xdigits = .false.
    b = 0
    n = len(s)
    if (n < 2) return
    if (str_lower(s(1:1)) /= 'x') return
    do i = 2, n
      if (s(i:i) < '0' .or. s(i:i) > '9') return
    end do
    call digits_to_int(s(2:n), b)
    match_xdigits = .true.
  end function match_xdigits

  ! ^rgb\((\d+),(\d+),(\d+)\)$ with re.I
  logical function match_rgb_tok(s, r, g, b)
    character(*), intent(in) :: s
    integer(int64), intent(out) :: r, g, b
    character(:), allocatable :: t
    integer(int64) :: parts(3)
    integer :: i, n, np, st
    match_rgb_tok = .false.
    r = 0; g = 0; b = 0
    t = str_lower(s)
    n = len(t)
    if (n < 10) return
    if (t(1:4) /= 'rgb(') return
    if (t(n:n) /= ')') return
    np = 0; st = 5
    do i = 5, n - 1
      if (t(i:i) == ',') then
        np = np + 1
        if (np > 2) return
        if (i == st) return
        call digits_to_int(t(st:i - 1), parts(np))
        st = i + 1
      else if (t(i:i) < '0' .or. t(i:i) > '9') then
        return
      end if
    end do
    if (np /= 2 .or. st > n - 1) return
    call digits_to_int(t(st:n - 1), parts(3))
    r = parts(1); g = parts(2); b = parts(3)
    match_rgb_tok = .true.
  end function match_rgb_tok

  ! ^repeat\((\d+)\)$ with re.I
  logical function match_repeat_tok(s, cnt)
    character(*), intent(in) :: s
    integer(int64), intent(out) :: cnt
    character(:), allocatable :: t
    integer :: i, n
    match_repeat_tok = .false.
    cnt = 0
    t = str_lower(s)
    n = len(t)
    if (n < 9) return
    if (t(1:7) /= 'repeat(') return
    if (t(n:n) /= ')') return
    do i = 8, n - 1
      if (t(i:i) < '0' .or. t(i:i) > '9') return
    end do
    call digits_to_int(t(8:n - 1), cnt)
    match_repeat_tok = .true.
  end function match_repeat_tok

  ! Digit string -> int64, saturating on overflow (Python ints are
  ! unbounded; only absurd literals diverge -- see report).
  subroutine digits_to_int(s, v)
    character(*), intent(in) :: s
    integer(int64), intent(out) :: v
    integer :: i
    v = 0_int64
    do i = 1, len(s)
      if (v > (huge(v) - 9_int64) / 10_int64) then
        v = huge(v)
        return
      end if
      v = v * 10_int64 + int(iachar(s(i:i)) - iachar('0'), int64)
    end do
  end subroutine digits_to_int

  ! ==================================================================
  ! Diagnostics: Parser.error / Parser._report_to_bag
  ! ==================================================================

  subroutine raise_line(p, code, msg)
    type(parser_state), intent(inout) :: p
    character(*), intent(in) :: code, msg
    p%le_set = .true.
    p%le_code = code
    p%le_msg = msg
  end subroutine raise_line

  subroutine clear_line_error(p)
    type(parser_state), intent(inout) :: p
    p%le_set = .false.
  end subroutine clear_line_error

  subroutine append_err(p, code, msg, line, col)
    type(parser_state), intent(inout) :: p
    character(*), intent(in) :: code, msg
    integer, intent(in) :: line, col
    type(err_rec), allocatable :: tmp(:)
    integer :: n
    if (.not. allocated(p%errs)) allocate(p%errs(0))
    n = size(p%errs)
    allocate(tmp(n + 1))
    if (n > 0) tmp(1:n) = p%errs
    tmp(n + 1)%code = code
    tmp(n + 1)%msg = msg
    tmp(n + 1)%line = line
    tmp(n + 1)%col = col
    call move_alloc(tmp, p%errs)
  end subroutine append_err

  ! Parser._report_to_bag: build the Diagnostic exactly as Python
  ! does (severity from the code, why/help extracted from a
  ! "did you mean 'x'" message, span line/col defaulting to 1).
  subroutine report_to_bag(p, code, msg, line, col)
    type(parser_state), intent(inout) :: p
    character(*), intent(in) :: code, msg
    integer, intent(in) :: line, col
    character(:), allocatable :: severity, why, help, cap
    integer :: idx, j, sline, scol
    if (.not. associated(p%bag)) return
    severity = "error"
    if (len(code) >= 1) then
      if (code(1:1) == 'W') severity = "warning"
    end if
    why = ""
    help = ""
    idx = index(msg, "did you mean '")
    if (idx > 0) then
      j = index(msg(idx + 14:), "'")
      if (j > 1) then
        cap = msg(idx + 14:idx + 14 + j - 2)
        help = "did you mean '" // cap // "'?"
        why = "the compiler does not know this word"
      end if
    end if
    sline = line
    if (sline == 0) sline = 1
    scol = col
    if (scol == 0) scol = 1
    call error_bag_add(p%bag, make_diagnostic_span( &
                         code, severity, msg, &
                         make_span(p%source, sline, scol, 1), &
                         why, help))
  end subroutine report_to_bag

  ! Parser.error: record, count syntax errors (E1/E2/E4 prefixes),
  ! report to the bag, and stop after 10 (E820).
  subroutine parser_error(p, code, msg, line, col)
    type(parser_state), intent(inout) :: p
    character(*), intent(in) :: code, msg
    integer, intent(in) :: line, col
    character(:), allocatable :: stopmsg
    call append_err(p, code, msg, line, col)
    if (len(code) >= 2) then
      if (code(1:2) == "E1" .or. code(1:2) == "E2" &
          .or. code(1:2) == "E4") p%syntax_errors = p%syntax_errors + 1
    end if
    call report_to_bag(p, code, msg, line, col)
    if (p%syntax_errors >= 10 .and. .not. p%stopped) then
      p%stopped = .true.
      stopmsg = "too many syntax errors (10) -- stopping parse"
      call append_err(p, "E820", stopmsg, line, col)
      call report_to_bag(p, "E820", stopmsg, line, col)
    end if
  end subroutine parser_error

  ! ==================================================================
  ! Token stream -> lines (Parser._lines)
  ! ==================================================================

  ! Parser._unquote: strip surrounding double quotes from a STRING.
  function unquote(s) result(r)
    character(*), intent(in) :: s
    character(:), allocatable :: r
    if (len(s) >= 2) then
      if (s(1:1) == '"' .and. s(len(s):len(s)) == '"') then
        r = s(2:len(s) - 1)
        return
      end if
    end if
    r = s
  end function unquote

  subroutine push_itok(arr, n, cap, t)
    type(itok), allocatable, intent(inout) :: arr(:)
    integer, intent(inout) :: n, cap
    type(itok), intent(in) :: t
    type(itok), allocatable :: tmp(:)
    if (n >= cap) then
      allocate(tmp(max(16, cap * 2)))
      if (n > 0) tmp(1:n) = arr
      call move_alloc(tmp, arr)
      cap = size(arr)
    end if
    n = n + 1
    arr(n) = t
  end subroutine push_itok

  subroutine push_line(lines, n, cap, no, cur, cn)
    type(line_rec), allocatable, intent(inout) :: lines(:)
    integer, intent(inout) :: n, cap
    integer, intent(in) :: no, cn
    type(itok), intent(in) :: cur(:)
    type(line_rec), allocatable :: tmp(:)
    integer :: i, m
    if (n >= cap) then
      allocate(tmp(max(16, cap * 2)))
      if (n > 0) tmp(1:n) = lines
      call move_alloc(tmp, lines)
      cap = size(lines)
    end if
    n = n + 1
    lines(n)%no = no
    ! _lines strips COMMA and COLON tokens from every line.
    m = 0
    do i = 1, cn
      if (cur(i)%kind /= K_COMMA .and. cur(i)%kind /= K_COLON) m = m + 1
    end do
    allocate(lines(n)%toks(m))
    m = 0
    do i = 1, cn
      if (cur(i)%kind /= K_COMMA .and. cur(i)%kind /= K_COLON) then
        m = m + 1
        lines(n)%toks(m) = cur(i)
      end if
    end do
  end subroutine push_line

  ! The ONLY place this module talks to f3dc_lexer: tokenise, convert
  ! to internal tokens (kind map + _ttext STRING unquoting), then
  ! group into lines exactly like Parser._lines.
  subroutine build_lines(p, text, lines, nlines)
    type(parser_state), intent(inout) :: p
    character(*), intent(in) :: text
    type(line_rec), allocatable, intent(out) :: lines(:)
    integer, intent(out) :: nlines
    type(token_list) :: raw
    type(itok), allocatable :: toks(:), cur(:)
    type(itok) :: t
    integer :: n, cap, cn, ccap, i, cur_no, ln
    logical :: has_nl
    call tokenize(text, p%source, raw, p%bag)
    allocate(toks(0))
    n = 0; cap = 0
    has_nl = .false.
    do i = 1, raw%count
      select case (raw%items(i)%kind)
      case (TK_EOF)
        cycle  ! Python drops EOF tokens before grouping
      case (TK_WORD);   t%kind = K_WORD
      case (TK_NUMBER); t%kind = K_NUMBER
      case (TK_STRING); t%kind = K_STRING
      case (TK_COLOR);  t%kind = K_COLOR
      case (TK_COMMA);  t%kind = K_COMMA
      case (TK_COLON);  t%kind = K_COLON
      case (TK_NEWLINE); t%kind = K_NEWLINE
      case default;      t%kind = K_OTHER
      end select
      if (allocated(raw%items(i)%text)) then
        t%text = raw%items(i)%text
      else
        t%text = ""
      end if
      if (t%kind == K_STRING) t%text = unquote(t%text)
      t%line = raw%items(i)%line
      t%col = raw%items(i)%col
      if (t%kind == K_NEWLINE) has_nl = .true.
      call push_itok(toks, n, cap, t)
    end do
    allocate(lines(0))
    nlines = 0; cap = 0
    allocate(cur(0))
    cn = 0; ccap = 0; cur_no = 0
    if (has_nl) then
      do i = 1, n
        t = toks(i)
        if (t%kind == K_NEWLINE) then
          call push_line(lines, nlines, cap, cur_no, cur, cn)
          cn = 0; cur_no = 0
        else
          if (cn == 0 .and. t%line /= 0) cur_no = t%line
          call push_itok(cur, cn, ccap, t)
        end if
      end do
      if (cn > 0) call push_line(lines, nlines, cap, cur_no, cur, cn)
    else
      ! Lexer without NEWLINE tokens: split on token line numbers.
      do i = 1, n
        t = toks(i)
        ln = t%line
        if (ln == 0) then
          ln = cur_no
          if (ln == 0) ln = 1
        end if
        if (cn > 0 .and. ln /= cur_no) then
          call push_line(lines, nlines, cap, cur_no, cur, cn)
          cn = 0
        end if
        cur_no = ln
        call push_itok(cur, cn, ccap, t)
      end do
      if (cn > 0) call push_line(lines, nlines, cap, cur_no, cur, cn)
    end if
  end subroutine build_lines

  ! ==================================================================
  ! _Line cursor basics
  ! ==================================================================

  ! _Line.__init__: drop COMMA/COLON, drop PUNCT except '(' and ')'.
  subroutine make_cur(toks, no, lp)
    type(itok), intent(in) :: toks(:)
    integer, intent(in) :: no
    type(line_cur), intent(out) :: lp
    integer :: i, m
    m = 0
    do i = 1, size(toks)
      if (toks(i)%kind == K_COMMA .or. toks(i)%kind == K_COLON) cycle
      if (toks(i)%kind == K_PUNCT) then
        if (allocated(toks(i)%text)) then
          if (toks(i)%text /= '(' .and. toks(i)%text /= ')') cycle
        else
          cycle
        end if
      end if
      m = m + 1
    end do
    allocate(lp%toks(m))
    m = 0
    do i = 1, size(toks)
      if (toks(i)%kind == K_COMMA .or. toks(i)%kind == K_COLON) cycle
      if (toks(i)%kind == K_PUNCT) then
        if (allocated(toks(i)%text)) then
          if (toks(i)%text /= '(' .and. toks(i)%text /= ')') cycle
        else
          cycle
        end if
      end if
      m = m + 1
      lp%toks(m) = toks(i)
    end do
    lp%i = 1
    lp%no = no
    if (lp%no == 0 .and. size(toks) > 0) lp%no = toks(1)%line
  end subroutine make_cur

  logical function lp_at_end(lp)
    type(line_cur), intent(in) :: lp
    lp_at_end = lp%i > size(lp%toks)
  end function lp_at_end

  function lp_peek_kind(lp) result(k)
    type(line_cur), intent(in) :: lp
    integer :: k
    if (lp_at_end(lp)) then
      k = K_EOF
    else
      k = lp%toks(lp%i)%kind
    end if
  end function lp_peek_kind

  subroutine lp_peek_text(lp, s)
    type(line_cur), intent(in) :: lp
    character(:), allocatable, intent(out) :: s
    if (lp_at_end(lp)) then
      s = ""
    else if (allocated(lp%toks(lp%i)%text)) then
      s = lp%toks(lp%i)%text
    else
      s = ""
    end if
  end subroutine lp_peek_text

  subroutine lp_peek_word(lp, w, has)
    type(line_cur), intent(in) :: lp
    character(:), allocatable, intent(out) :: w
    logical, intent(out) :: has
    character(:), allocatable :: s
    has = .false.
    w = ""
    if (lp_peek_kind(lp) == K_WORD) then
      call lp_peek_text(lp, s)
      w = word_norm(s)
      has = .true.
    end if
  end subroutine lp_peek_word

  subroutine lp_next(lp)
    type(line_cur), intent(inout) :: lp
    lp%i = lp%i + 1
  end subroutine lp_next

  subroutine lp_next_text(lp, s)
    type(line_cur), intent(inout) :: lp
    character(:), allocatable, intent(out) :: s
    call lp_peek_text(lp, s)
    lp%i = lp%i + 1
  end subroutine lp_next_text

  ! _Line.dup: E110 when a property word is given twice.
  subroutine lp_dup(p, seen, key)
    type(parser_state), intent(inout) :: p
    type(str_set), intent(inout) :: seen
    character(*), intent(in) :: key
    if (set_has(seen, key)) then
      call raise_line(p, "E110", "'" // key // &
                      "' given twice in one statement")
      return
    end if
    call set_add(seen, key)
  end subroutine lp_dup

  ! _Line.ident: WORD or STRING text, else None.
  subroutine lp_ident(lp, s, has)
    type(line_cur), intent(inout) :: lp
    character(:), allocatable, intent(out) :: s
    logical, intent(out) :: has
    integer :: k
    k = lp_peek_kind(lp)
    if (k == K_WORD .or. k == K_STRING) then
      call lp_next_text(lp, s)
      has = .true.
    else
      s = ""
      has = .false.
    end if
  end subroutine lp_ident

  ! ==================================================================
  ! _Line value helpers
  ! ==================================================================

  ! _Line.number: a NUMBER token through _num, else E102.  Note the
  ! Python error text peeks AFTER a failed _num consumed the token.
  subroutine lp_number(p, lp, what, val)
    type(parser_state), intent(inout) :: p
    type(line_cur), intent(inout) :: lp
    character(*), intent(in) :: what
    type(dyn), intent(out) :: val
    character(:), allocatable :: txt, pt
    logical :: ok
    val = dyn_null()
    if (lp_peek_kind(lp) == K_NUMBER) then
      call lp_next_text(lp, txt)
      call parse_num(txt, val, ok)
      if (ok) return
    end if
    call lp_peek_text(lp, pt)
    call raise_line(p, "E102", "expected a number for " // what &
                    // ", got '" // pt // "'")
  end subroutine lp_number

  ! _Line._numbers_ahead: consecutive NUMBER tokens as _num values
  ! (dyn_null where _num returned None).
  subroutine lp_numbers_ahead(lp, vals, n)
    type(line_cur), intent(in) :: lp
    type(dyn), allocatable, intent(out) :: vals(:)
    integer, intent(out) :: n
    integer :: j
    logical :: ok
    n = 0
    j = lp%i
    do while (j <= size(lp%toks))
      if (lp%toks(j)%kind /= K_NUMBER) exit
      n = n + 1
      j = j + 1
    end do
    allocate(vals(n))
    do j = 1, n
      if (allocated(lp%toks(lp%i + j - 1)%text)) then
        call parse_num(lp%toks(lp%i + j - 1)%text, vals(j), ok)
      else
        call parse_num("", vals(j), ok)
      end if
      if (.not. ok) vals(j) = dyn_null()
    end do
  end subroutine lp_numbers_ahead

  ! _Line.vec3: parenthesised '(' n n n ')' or 3 consecutive numbers.
  subroutine lp_vec3(p, lp, val)
    type(parser_state), intent(inout) :: p
    type(line_cur), intent(inout) :: lp
    type(dyn), intent(out) :: val
    type(dyn) :: a, b, c
    type(dyn), allocatable :: nums(:)
    character(:), allocatable :: s
    integer :: n
    val = dyn_null()
    call lp_peek_text(lp, s)
    if (s == "(") then
      call lp_next(lp)
      call lp_number(p, lp, "vec3", a)
      if (p%le_set) return
      call lp_number(p, lp, "vec3", b)
      if (p%le_set) return
      call lp_number(p, lp, "vec3", c)
      if (p%le_set) return
      call lp_peek_text(lp, s)
      if (s == ")") call lp_next(lp)
      val = vec3_of(a, b, c)
      return
    end if
    call lp_numbers_ahead(lp, nums, n)
    if (n < 3) then
      call raise_line(p, "E102", "expected 3 numbers (a vec3), got " &
                      // itoa(int(n, int64)))
      return
    end if
    lp%i = lp%i + 3
    val = vec3_of(nums(1), nums(2), nums(3))
  end subroutine lp_vec3

  ! _Line.num_or_vec3: vec3 only when exactly 3 numbers are followed
  ! by a word / end of line, else a scalar.
  subroutine lp_num_or_vec3(p, lp, val)
    type(parser_state), intent(inout) :: p
    type(line_cur), intent(inout) :: lp
    type(dyn), intent(out) :: val
    type(dyn), allocatable :: nums(:)
    character(:), allocatable :: pt
    integer :: n
    logical :: is_vec
    val = dyn_null()
    call lp_numbers_ahead(lp, nums, n)
    if (n == 0) then
      call lp_peek_text(lp, pt)
      call raise_line(p, "E102", "expected a number, got '" // pt // "'")
      return
    end if
    is_vec = .false.
    if (n >= 3) then
      is_vec = lp%i + 3 > size(lp%toks)
      if (.not. is_vec) is_vec = lp%toks(lp%i + 3)%kind == K_WORD
    end if
    if (is_vec) then
      lp%i = lp%i + 3
      val = vec3_of(nums(1), nums(2), nums(3))
    else
      lp%i = lp%i + 1
      call dyn_assign(val, nums(1))
    end if
  end subroutine lp_num_or_vec3

  ! _Line.colour: COLOR lexeme as-is, rgb forms as an int triple,
  ! any other WORD lower-cased (validate owns the real palette).
  subroutine lp_colour(p, lp, val)
    type(parser_state), intent(inout) :: p
    type(line_cur), intent(inout) :: lp
    type(dyn), intent(out) :: val
    type(dyn) :: a, b, c
    type(dyn), allocatable :: nums(:)
    character(:), allocatable :: s, w, pt
    integer(int64) :: r, g, bl
    integer :: n
    logical :: hasw
    val = dyn_null()
    if (lp_at_end(lp)) then
      call raise_line(p, "E101", "expected a colour")
      return
    end if
    if (lp_peek_kind(lp) == K_COLOR) then
      call lp_next_text(lp, s)
      val = dyn_str(s)
      return
    end if
    call lp_peek_word(lp, w, hasw)
    if (hasw .and. w == "rgb") then
      call lp_next(lp)
      call lp_peek_text(lp, s)
      if (s == "(") then
        call lp_next(lp)
        call lp_number(p, lp, "rgb", a)
        if (p%le_set) return
        call lp_number(p, lp, "rgb", b)
        if (p%le_set) return
        call lp_number(p, lp, "rgb", c)
        if (p%le_set) return
        call lp_peek_text(lp, s)
        if (s == ")") call lp_next(lp)
        val = vec3_of(dyn_int(dyn_to_int(a)), dyn_int(dyn_to_int(b)), &
                      dyn_int(dyn_to_int(c)))
        return
      end if
      if (match_rgb_tok(s, r, g, bl)) then
        call lp_next(lp)
        val = vec3_of(dyn_int(r), dyn_int(g), dyn_int(bl))
        return
      end if
      call lp_numbers_ahead(lp, nums, n)
      if (n < 3) then
        call raise_line(p, "E102", "'rgb' needs 3 numbers")
        return
      end if
      lp%i = lp%i + 3
      val = vec3_of(dyn_int(dyn_to_int(nums(1))), &
                    dyn_int(dyn_to_int(nums(2))), &
                    dyn_int(dyn_to_int(nums(3))))
      return
    end if
    call lp_peek_text(lp, s)
    if (match_rgb_tok(s, r, g, bl)) then
      call lp_next(lp)
      val = vec3_of(dyn_int(r), dyn_int(g), dyn_int(bl))
      return
    end if
    if (lp_peek_kind(lp) == K_WORD) then
      call lp_next_text(lp, s)
      val = dyn_str(str_lower(s))
      return
    end if
    call lp_peek_text(lp, pt)
    call raise_line(p, "E102", "expected a colour, got '" // pt // "'")
  end subroutine lp_colour

  ! _Line.peek_size_token: single '800x600' token, or NUMBER followed
  ! by WORD 'x600', or NUMBER + WORD 'x' + NUMBER.
  logical function lp_peek_size_token(lp)
    type(line_cur), intent(in) :: lp
    character(:), allocatable :: s, nt
    integer(int64) :: a, b
    lp_peek_size_token = .false.
    call lp_peek_text(lp, s)
    if (match_size_tok(s, a, b)) then
      lp_peek_size_token = .true.
      return
    end if
    if (lp_peek_kind(lp) /= K_NUMBER) return
    if (lp%i + 1 > size(lp%toks)) return
    if (allocated(lp%toks(lp%i + 1)%text)) then
      nt = lp%toks(lp%i + 1)%text
    else
      nt = ""
    end if
    if (match_xdigits(nt, b)) then
      lp_peek_size_token = .true.
      return
    end if
    if (str_lower(nt) == "x") then
      if (lp%i + 2 > size(lp%toks)) return
      lp_peek_size_token = lp%toks(lp%i + 2)%kind == K_NUMBER
    end if
  end function lp_peek_size_token

  ! _Line._second_of_pair: WORD 'x600', WORD 'x' + NUMBER, bare NUMBER.
  subroutine lp_second_of_pair(p, lp, what, v, has)
    type(parser_state), intent(inout) :: p
    type(line_cur), intent(inout) :: lp
    character(*), intent(in) :: what
    integer(int64), intent(out) :: v
    logical, intent(out) :: has
    type(dyn) :: tmp
    character(:), allocatable :: s, w
    integer(int64) :: b
    logical :: hasw
    v = 0_int64
    has = .false.
    call lp_peek_text(lp, s)
    if (lp_peek_kind(lp) == K_WORD .and. match_xdigits(s, b)) then
      call lp_next(lp)
      v = b
      has = .true.
      return
    end if
    call lp_peek_word(lp, w, hasw)
    if (hasw .and. w == "x") then
      call lp_next(lp)
      call lp_number(p, lp, what, tmp)
      if (p%le_set) return
      v = dyn_to_int(tmp)
      has = .true.
      return
    end if
    if (lp_peek_kind(lp) == K_NUMBER) then
      call lp_number(p, lp, what, tmp)
      if (p%le_set) return
      v = dyn_to_int(tmp)
      has = .true.
      return
    end if
  end subroutine lp_second_of_pair

  ! _Line.size: (width, height) as ints.
  subroutine lp_size(p, lp, w, h)
    type(parser_state), intent(inout) :: p
    type(line_cur), intent(inout) :: lp
    integer(int64), intent(out) :: w, h
    type(dyn) :: tmp
    character(:), allocatable :: s, pt
    integer(int64) :: a, b, hv
    logical :: has
    w = 0_int64; h = 0_int64
    call lp_peek_text(lp, s)
    if (match_size_tok(s, a, b)) then
      call lp_next(lp)
      w = a; h = b
      return
    end if
    call lp_number(p, lp, "size width", tmp)
    if (p%le_set) return
    w = dyn_to_int(tmp)
    call lp_second_of_pair(p, lp, "size height", hv, has)
    if (p%le_set) return
    if (.not. has) then
      call lp_peek_text(lp, pt)
      call raise_line(p, "E102", "expected a size height, got '" &
                      // pt // "'")
      return
    end if
    h = hv
  end subroutine lp_size

  ! _Line.grid_size: like size, but a missing second value repeats.
  subroutine lp_grid_size(p, lp, a, b)
    type(parser_state), intent(inout) :: p
    type(line_cur), intent(inout) :: lp
    integer(int64), intent(out) :: a, b
    type(dyn) :: tmp
    character(:), allocatable :: s
    integer(int64) :: x, y, hv
    logical :: has
    a = 0_int64; b = 0_int64
    call lp_peek_text(lp, s)
    if (match_size_tok(s, x, y)) then
      call lp_next(lp)
      a = x; b = y
      return
    end if
    call lp_number(p, lp, "grid rows", tmp)
    if (p%le_set) return
    a = dyn_to_int(tmp)
    call lp_second_of_pair(p, lp, "grid cols", hv, has)
    if (p%le_set) return
    if (has) then
      b = hv
    else
      b = a
    end if
  end subroutine lp_grid_size

  ! _Line.loop_repeat: 'repeat' + optional count -> 'repeat(N)' text.
  subroutine lp_loop_repeat(p, lp, s)
    type(parser_state), intent(inout) :: p
    type(line_cur), intent(inout) :: lp
    character(:), allocatable, intent(out) :: s
    type(dyn) :: tmp
    character(:), allocatable :: pt
    integer(int64) :: cnt
    call lp_next(lp)  ! 'repeat'
    call lp_peek_text(lp, pt)
    if (pt == "(") then
      call lp_next(lp)
      call lp_number(p, lp, "repeat count", tmp)
      if (p%le_set) then; s = ""; return; end if
      call lp_peek_text(lp, pt)
      if (pt == ")") call lp_next(lp)
      s = "repeat(" // itoa(dyn_to_int(tmp)) // ")"
      return
    end if
    if (match_repeat_tok(pt, cnt)) then
      call lp_next(lp)
      s = "repeat(" // itoa(cnt) // ")"
      return
    end if
    if (lp_peek_kind(lp) == K_NUMBER) then
      call lp_number(p, lp, "repeat count", tmp)
      if (p%le_set) then; s = ""; return; end if
      s = "repeat(" // itoa(dyn_to_int(tmp)) // ")"
      return
    end if
    s = "repeat"
  end subroutine lp_loop_repeat

  ! ==================================================================
  ! Object-style properties (Parser._object_props)
  ! ==================================================================

  subroutine object_props(p, lp, props, seen, handled)
    type(parser_state), intent(inout) :: p
    type(line_cur), intent(inout) :: lp
    type(dyn), intent(inout) :: props
    type(str_set), intent(inout) :: seen
    logical, intent(out) :: handled
    type(dyn) :: v, v2
    type(dyn), allocatable :: nums(:)
    character(:), allocatable :: w, s, d
    integer :: n, width, i, j
    logical :: hasw, hasid
    handled = .false.
    call lp_peek_word(lp, w, hasw)
    if (.not. hasw) return
    if (w == "at" .or. w == "pos" .or. w == "position") then
      call lp_next(lp)
      call lp_dup(p, seen, "at")
      if (p%le_set) return
      call lp_vec3(p, lp, v)
      if (p%le_set) return
      call dset(props, "at", v)
      call dset(props, "pos", dyn_copy(v))
    else if (w == "size") then
      call lp_next(lp)
      call lp_dup(p, seen, "size")
      if (p%le_set) return
      call lp_num_or_vec3(p, lp, v)
      if (p%le_set) return
      call dset(props, "size", v)
    else if (w == "radius" .or. w == "height" .or. w == "width" &
             .or. w == "depth") then
      call lp_next(lp)
      call lp_dup(p, seen, w)
      if (p%le_set) return
      call lp_number(p, lp, w, v)
      if (p%le_set) return
      call dset(props, w, v)
    else if (w == "inner" .or. w == "outer" .or. w == "tube" &
             .or. w == "extrude_depth") then
      ! Wave D scalar geometry props (ext_geometry).
      call lp_next(lp)
      call lp_dup(p, seen, w)
      if (p%le_set) return
      call lp_number(p, lp, w, v)
      if (p%le_set) return
      call dset(props, w, v)
    else if (w == "tube_segments") then
      call lp_next(lp)
      call lp_dup(p, seen, w)
      if (p%le_set) return
      call lp_number(p, lp, w, v)
      if (p%le_set) return
      call dset(props, w, dyn_int(dyn_to_int(v)))
    else if (w == "path" .or. w == "points" .or. w == "shape") then
      ! Wave D list geometry props: consecutive numbers grouped --
      ! triples for a tube path, pairs for lathe points / shape.
      call lp_next(lp)
      call lp_dup(p, seen, w)
      if (p%le_set) return
      width = 2
      if (w == "path") width = 3
      call lp_numbers_ahead(lp, nums, n)
      if (n == 0 .or. mod(n, width) /= 0) then
        call raise_line(p, "E102", "'" // w // &
                        "' needs groups of " // itoa(int(width, int64)) &
                        // " numbers, got " // itoa(int(n, int64)))
        return
      end if
      lp%i = lp%i + n
      v = dyn_list()
      do i = 1, n, width
        v2 = dyn_list()
        do j = 0, width - 1
          call dyn_list_push(v2, nums(i + j))
        end do
        call dyn_list_push(v, v2)
      end do
      call dset(props, w, v)
    else if (w == "rotate" .or. w == "rot") then
      call lp_next(lp)
      call lp_dup(p, seen, "rotate")
      if (p%le_set) return
      call lp_vec3(p, lp, v)
      if (p%le_set) return
      call dset(props, "rotate", v)
      call dset(props, "rot", dyn_copy(v))
    else if (w == "scale") then
      call lp_next(lp)
      call lp_dup(p, seen, "scale")
      if (p%le_set) return
      call lp_num_or_vec3(p, lp, v)
      if (p%le_set) return
      call dset(props, "scale", v)
    else if (w == "material") then
      call lp_next(lp)
      call lp_dup(p, seen, "material")
      if (p%le_set) return
      call lp_ident(lp, s, hasid)
      if (hasid) then
        call dset(props, "material", dyn_str(s))
      else
        call dset(props, "material", dyn_null())
      end if
    else if (w == "shader") then
      ! Wave E (C2): bind a named custom shader to this object.
      call lp_next(lp)
      call lp_dup(p, seen, "shader")
      if (p%le_set) return
      call lp_ident(lp, s, hasid)
      if (hasid) then
        call dset(props, "shader", dyn_str(s))
      else
        call dset(props, "shader", dyn_null())
      end if
    else if (w == "metalness" .or. w == "roughness" .or. &
             w == "specular" .or. w == "shininess") then
      call lp_next(lp)
      call lp_dup(p, seen, w)
      if (p%le_set) return
      call lp_number(p, lp, w, v)
      if (p%le_set) return
      call dset(props, w, v)
    else if (w == "segments") then
      call lp_next(lp)
      call lp_dup(p, seen, "segments")
      if (p%le_set) return
      call lp_number(p, lp, "segments", v)
      if (p%le_set) return
      call dset(props, "segments", dyn_int(dyn_to_int(v)))
    else if (w == "detail") then
      call lp_next(lp)
      call lp_dup(p, seen, "detail")
      if (p%le_set) return
      call lp_ident(lp, d, hasid)
      if (hasid) then
        if (.not. (str_lower(d) == "low" .or. str_lower(d) == "med" &
                   .or. str_lower(d) == "high")) then
          call raise_line(p, "E103", "detail must be low, med or " &
                          // "high, got '" // d // "'")
          return
        end if
        call dset(props, "detail", dyn_str(str_lower(d)))
      else
        call dset(props, "detail", dyn_null())
      end if
    else if (w == "shading") then
      call lp_next(lp)
      call lp_dup(p, seen, "shading")
      if (p%le_set) return
      call lp_ident(lp, d, hasid)
      if (hasid) then
        if (.not. (str_lower(d) == "smooth" .or. &
                   str_lower(d) == "flat")) then
          call raise_line(p, "E103", "shading must be smooth or " &
                          // "flat, got '" // d // "'")
          return
        end if
        call dset(props, "shading", dyn_str(str_lower(d)))
      else
        call dset(props, "shading", dyn_null())
      end if
    else if (w == "mirror") then
      ! P3: per-object mirror axis (x|y|z), no scene-level default.
      call lp_next(lp)
      call lp_dup(p, seen, "mirror")
      if (p%le_set) return
      call lp_ident(lp, d, hasid)
      if (hasid) then
        if (.not. (str_lower(d) == "x" .or. str_lower(d) == "y" &
                   .or. str_lower(d) == "z")) then
          call raise_line(p, "E103", "mirror must be x, y or " &
                          // "z, got '" // d // "'")
          return
        end if
        call dset(props, "mirror", dyn_str(str_lower(d)))
      else
        call dset(props, "mirror", dyn_null())
      end if
    else if (w == "capped") then
      call lp_next(lp)
      call lp_dup(p, seen, "capped")
      if (p%le_set) return
      call dset(props, "capped", dyn_bool(.true.))
    else if (w == "open") then
      call lp_next(lp)
      call lp_dup(p, seen, "open")
      if (p%le_set) return
      call dset(props, "open", dyn_bool(.true.))
    else if (w == "texture" .or. w == "normalmap" .or. w == "mr" &
             .or. w == "emissivemap" .or. w == "occlusionmap") then
      ! 'texture' is the Wave A base-colour slot; the other four are
      ! the v3.0 Phase 4 PBR slots.  All five share the exact same
      ! value handling (quoted string, or a bare identifier).
      call lp_next(lp)
      call lp_dup(p, seen, w)
      if (p%le_set) return
      if (lp_peek_kind(lp) == K_STRING) then
        call lp_next_text(lp, s)
        call dset(props, w, dyn_str(s))
      else
        call lp_ident(lp, s, hasid)
        if (hasid) then
          call dset(props, w, dyn_str(s))
        else
          call dset(props, w, dyn_null())
        end if
      end if
    else if (w == "emissive") then
      ! v3.0 Phase 4 material key: emissive colour (same colour
      ! grammar as the object colour prop).
      call lp_next(lp)
      call lp_dup(p, seen, "emissive")
      if (p%le_set) return
      call lp_colour(p, lp, v)
      if (p%le_set) return
      call dset(props, "emissive", v)
    else if (w == "opacity" .or. w == "cutoff") then
      ! v3.0 Phase 4 material keys: plain numbers, like metalness.
      call lp_next(lp)
      call lp_dup(p, seen, w)
      if (p%le_set) return
      call lp_number(p, lp, w, v)
      if (p%le_set) return
      call dset(props, w, v)
    else if (w == "alpha") then
      ! v3.0 Phase 4 material key: alpha mode word.
      call lp_next(lp)
      call lp_dup(p, seen, "alpha")
      if (p%le_set) return
      call lp_ident(lp, d, hasid)
      if (hasid) then
        if (.not. (str_lower(d) == "opaque" .or. &
                   str_lower(d) == "mask" .or. &
                   str_lower(d) == "blend")) then
          call raise_line(p, "E103", "alpha must be opaque, mask " &
                          // "or blend, got '" // d // "'")
          return
        end if
        call dset(props, "alpha", dyn_str(str_lower(d)))
      else
        call dset(props, "alpha", dyn_null())
      end if
    else if (w == "colour" .or. w == "color") then
      call lp_next(lp)
      call lp_dup(p, seen, "colour")
      if (p%le_set) return
      call lp_colour(p, lp, v)
      if (p%le_set) return
      call dset(props, "colour", v)
      call dset(props, "color", dyn_copy(v))
    else
      return
    end if
    handled = .true.
  end subroutine object_props

  ! Shared tail of object/sprite/text parsing: a colour that arrived
  ! via object_props is adopted, then colour/color are setdefaulted.
  subroutine adopt_colour(props, colour, has_colour)
    type(dyn), intent(inout) :: props
    type(dyn), intent(inout) :: colour
    logical, intent(inout) :: has_colour
    type(dyn) :: v
    if (.not. has_colour) then
      if (dyn_dict_has(props, "colour")) then
        v = dget(props, "colour")
        if (v%kind /= DYN_K_NULL) then
          call dyn_assign(colour, v)
          has_colour = .true.
        end if
      else if (dyn_dict_has(props, "color")) then
        v = dget(props, "color")
        if (v%kind /= DYN_K_NULL) then
          call dyn_assign(colour, v)
          has_colour = .true.
        end if
      end if
    end if
    if (has_colour) then
      if (.not. dyn_dict_has(props, "colour")) &
        call dset(props, "colour", dyn_copy(colour))
      if (.not. dyn_dict_has(props, "color")) &
        call dset(props, "color", dyn_copy(colour))
    end if
  end subroutine adopt_colour

  ! Parser._parse_object.
  subroutine parse_object(p, lp, stmt, has_stmt)
    type(parser_state), intent(inout) :: p
    type(line_cur), intent(inout) :: lp
    type(dyn), intent(out) :: stmt
    logical, intent(out) :: has_stmt
    character(:), allocatable :: prim, s, w, key
    type(dyn) :: name, colour, props, node, v
    type(str_set) :: seen
    logical :: hasw, hasid, name_null, has_colour, handled
    integer :: i
    has_stmt = .false.
    stmt = dyn_null()
    call lp_next_text(lp, s)
    prim = str_lower(s)
    name = dyn_null()
    name_null = .true.
    colour = dyn_null()
    has_colour = .false.
    props = dyn_dict()
    seen%n = 0
    ! Optional [name] / [colour] / 'named NAME' after the primitive.
    do while (.not. lp_at_end(lp))
      call lp_peek_word(lp, w, hasw)
      if (hasw .and. w == "named") then
        call lp_next(lp)
        call lp_ident(lp, s, hasid)
        if (hasid) then
          name = dyn_str(s)
          name_null = .false.
        else
          name = dyn_null()
          name_null = .true.
        end if
        cycle
      end if
      if (lp_peek_kind(lp) == K_COLOR .or. (hasw .and. w == "rgb")) then
        call lp_dup(p, seen, "colour")
        if (p%le_set) return
        call lp_colour(p, lp, colour)
        if (p%le_set) return
        has_colour = .true.
        cycle
      end if
      if (hasw .and. .not. in_list(w, OBJECT_PROP_WORDS) &
          .and. .not. in_list(w, RESERVED_ALL)) then
        if (in_list(w, COLOUR_WORDS)) then
          call lp_dup(p, seen, "colour")
          if (p%le_set) return
          call lp_colour(p, lp, colour)
          if (p%le_set) return
          has_colour = .true.
          cycle
        end if
        if (name_null) then
          call lp_next_text(lp, s)
          name = dyn_str(s)
          name_null = .false.
          cycle
        end if
        call raise_line(p, "E103", "unexpected word '" // w &
                        // "' after " // prim // " name")
        return
      end if
      exit
    end do
    do while (.not. lp_at_end(lp))
      call object_props(p, lp, props, seen, handled)
      if (p%le_set) return
      if (handled) cycle
      call lp_peek_word(lp, w, hasw)
      if (lp_peek_kind(lp) == K_COLOR .or. (hasw .and. w == "rgb") &
          .or. (hasw .and. in_list(w, COLOUR_WORDS))) then
        call lp_dup(p, seen, "colour")
        if (p%le_set) return
        call lp_colour(p, lp, colour)
        if (p%le_set) return
        has_colour = .true.
        cycle
      end if
      call lp_peek_text(lp, s)
      call raise_line(p, "E103", "unexpected '" // s // "' in " &
                      // prim // " statement")
      return
    end do
    call adopt_colour(props, colour, has_colour)
    ! _make("ObjectStmt", ...): dataclass fields first, then the
    ! remaining fields in call order, then the props spread.
    node = dyn_dict()
    call dset(node, "prim", dyn_str(prim))
    call dset(node, "name", dyn_copy(name))
    call dset(node, "color_raw", colour_raw_str(colour, has_colour))
    call dset(node, "props", dyn_copy(props))
    call dset(node, "span", dyn_null())
    call dset(node, "primitive", dyn_str(prim))
    call dset(node, "type", dyn_str(prim))
    call dset(node, "kind", dyn_str(prim))
    if (has_colour) then
      call dset(node, "colour", dyn_copy(colour))
      call dset(node, "color", dyn_copy(colour))
    else
      call dset(node, "colour", dyn_null())
      call dset(node, "color", dyn_null())
    end if
    call dset(node, "colour_raw", colour_raw_str(colour, has_colour))
    call dset(node, "line", dyn_int(int(lp%no, int64)))
    do i = 1, dyn_dict_len(props)
      key = dyn_dict_key_at(props, i)
      if (key == "prim" .or. key == "primitive" .or. key == "type" &
          .or. key == "kind" .or. key == "name" .or. key == "line" &
          .or. key == "span" .or. key == "props" .or. key == "colour" &
          .or. key == "color") cycle
      v = dget(props, key)
      call dset(node, key, v)
    end do
    call dyn_assign(stmt, node)
    has_stmt = .true.
  end subroutine parse_object

  ! Parser._parse_scene.
  subroutine parse_scene(p, lp, stmt, has_stmt)
    type(parser_state), intent(inout) :: p
    type(line_cur), intent(inout) :: lp
    type(dyn), intent(out) :: stmt
    logical, intent(out) :: has_stmt
    character(:), allocatable :: w, w2, s, key, parts
    type(str_builder) :: sb_parts
    character(16) :: env_keys(4)
    character(8192) :: env_vals(4)  ! clause text (lexer caps lines at 4096)
    type(dyn) :: name, bg, props, node
    type(str_set) :: seen
    integer(int64) :: sw, sh
    integer :: nenv, i
    logical :: hasw, hasw2, has_name, has_size, has_bg, dupf
    logical :: has_shading, hasid
    character(:), allocatable :: shading_val, d
    has_stmt = .false.
    stmt = dyn_null()
    call lp_next(lp)  ! scene
    name = dyn_null()
    has_name = .false.
    bg = dyn_null()
    has_bg = .false.
    has_size = .false.
    has_shading = .false.
    shading_val = ""
    sw = 0_int64; sh = 0_int64
    nenv = 0
    seen%n = 0
    do while (.not. lp_at_end(lp))
      call lp_peek_word(lp, w, hasw)
      if (hasw .and. w == "size") then
        call lp_next(lp)
        call lp_dup(p, seen, "size")
        if (p%le_set) return
        call lp_size(p, lp, sw, sh)
        if (p%le_set) return
        has_size = .true.
      else if (hasw .and. w == "shading") then
        ! P1: scene-level default shading for all objects.
        call lp_next(lp)
        call lp_dup(p, seen, "shading")
        if (p%le_set) return
        call lp_ident(lp, d, hasid)
        if (hasid) then
          if (.not. (str_lower(d) == "smooth" .or. &
                     str_lower(d) == "flat")) then
            call raise_line(p, "E103", "shading must be smooth or " &
                            // "flat, got '" // d // "'")
            return
          end if
          shading_val = str_lower(d)
          has_shading = .true.
        end if
      else if (hasw .and. (w == "fog" .or. w == "tonemap" &
               .or. w == "tone" .or. w == "shadow" &
               .or. w == "antialias")) then
        ! Wave A environment clause: tokens up to the next clause
        ! keyword; ext_lights_env owns the semantics.  (v3.0 Phase 2:
        ! "antialias" rides the same clause path.)
        if (w == "tonemap" .or. w == "tone") then
          key = "tonemap"
        else
          key = w
        end if
        call lp_next(lp)
        call lp_dup(p, seen, key)
        if (p%le_set) return
        call sb_init(sb_parts)
        call sb_add(sb_parts, w)
        do while (.not. lp_at_end(lp))
          call lp_peek_word(lp, w2, hasw2)
          if (hasw2 .and. in_list(w2, SCENE_CLAUSES)) exit
          call lp_next_text(lp, s)
          call sb_add(sb_parts, " ")
          call sb_add(sb_parts, s)
        end do
        parts = sb_text(sb_parts)
        dupf = .false.
        do i = 1, nenv
          if (env_keys(i) == key) then
            env_vals(i) = parts
            dupf = .true.
          end if
        end do
        if (.not. dupf) then
          nenv = nenv + 1
          env_keys(nenv) = key
          env_vals(nenv) = parts
        end if
      else if (hasw .and. (w == "bg" .or. w == "background" &
               .or. w == "colour" .or. w == "color")) then
        call lp_next(lp)
        call lp_dup(p, seen, "background")
        if (p%le_set) return
        call lp_colour(p, lp, bg)
        if (p%le_set) return
        has_bg = .true.
      else if (lp_peek_kind(lp) == K_STRING .and. .not. has_name) then
        call lp_next_text(lp, s)
        name = dyn_str(s)
        has_name = .true.
      else if (lp_peek_size_token(lp)) then
        call lp_dup(p, seen, "size")
        if (p%le_set) return
        call lp_size(p, lp, sw, sh)
        if (p%le_set) return
        has_size = .true.
      else if (hasw .and. .not. has_name &
               .and. .not. in_list(w, RESERVED_ALL)) then
        call lp_next_text(lp, s)
        name = dyn_str(s)
        has_name = .true.
      else
        call lp_peek_text(lp, s)
        call raise_line(p, "E103", "unexpected '" // s &
                        // "' in scene statement")
        return
      end if
    end do
    props = dyn_dict()
    if (has_size) then
      call dset(props, "size", pair_of(sw, sh))
    else
      call dset(props, "size", dyn_null())
    end if
    if (has_bg) then
      call dset(props, "background", dyn_copy(bg))
    else
      call dset(props, "background", dyn_null())
    end if
    if (has_shading) &
      call dset(props, "shading", dyn_str(shading_val))
    do i = 1, nenv
      call dset(props, trim(env_keys(i)), dyn_str(trim(env_vals(i))))
    end do
    node = dyn_dict()
    call dset(node, "name", dyn_copy(name))
    if (has_size) then
      call dset(node, "width", dyn_int(sw))
      call dset(node, "height", dyn_int(sh))
    else
      call dset(node, "width", dyn_null())
      call dset(node, "height", dyn_null())
    end if
    if (has_bg) then
      call dset(node, "bg", dyn_copy(bg))
    else
      call dset(node, "bg", dyn_null())
    end if
    call dset(node, "span", dyn_null())
    if (has_size) then
      call dset(node, "size", pair_of(sw, sh))
    else
      call dset(node, "size", dyn_null())
    end if
    if (has_bg) then
      call dset(node, "background", dyn_copy(bg))
      call dset(node, "colour", dyn_copy(bg))
      call dset(node, "color", dyn_copy(bg))
    else
      call dset(node, "background", dyn_null())
      call dset(node, "colour", dyn_null())
      call dset(node, "color", dyn_null())
    end if
    ! fog / tonemap / shadow / antialias fields (null when absent)
    block
      character(16) :: want(4)
      integer :: k
      want = [character(16) :: "fog", "tonemap", "shadow", &
              "antialias"]
      do k = 1, 4
        dupf = .false.
        do i = 1, nenv
          if (env_keys(i) == trim(want(k))) then
            call dset(node, trim(want(k)), dyn_str(trim(env_vals(i))))
            dupf = .true.
          end if
        end do
        if (.not. dupf) call dset(node, trim(want(k)), dyn_null())
      end do
    end block
    if (has_shading) &
      call dset(node, "shading", dyn_str(shading_val))
    call dset(node, "props", props)
    call dset(node, "line", dyn_int(int(lp%no, int64)))
    call dyn_assign(stmt, node)
    has_stmt = .true.
  end subroutine parse_scene

  ! Parser._parse_camera.
  subroutine parse_camera(p, lp, stmt, has_stmt)
    type(parser_state), intent(inout) :: p
    type(line_cur), intent(inout) :: lp
    type(dyn), intent(out) :: stmt
    logical, intent(out) :: has_stmt
    character(:), allocatable :: w, s
    type(dyn) :: props, node, v
    type(str_set) :: seen
    logical :: hasw
    has_stmt = .false.
    stmt = dyn_null()
    call lp_next(lp)  ! camera
    props = dyn_dict()
    seen%n = 0
    do while (.not. lp_at_end(lp))
      call lp_peek_word(lp, w, hasw)
      if (hasw .and. (w == "at" .or. w == "look" .or. w == "up")) then
        call lp_next(lp)
        call lp_dup(p, seen, w)
        if (p%le_set) return
        call lp_vec3(p, lp, v)
        if (p%le_set) return
        call dset(props, w, v)
      else if (hasw .and. (w == "fov" .or. w == "near" &
               .or. w == "far")) then
        call lp_next(lp)
        call lp_dup(p, seen, w)
        if (p%le_set) return
        call lp_number(p, lp, w, v)
        if (p%le_set) return
        call dset(props, w, v)
      else if (hasw .and. w == "size") then
        ! Wave C: ortho frustum height (`camera ortho size N`).
        call lp_next(lp)
        call lp_dup(p, seen, w)
        if (p%le_set) return
        call lp_number(p, lp, w, v)
        if (p%le_set) return
        call dset(props, w, v)
      else if (hasw .and. w == "ortho") then
        call lp_next(lp)
        call dset(props, "ortho", dyn_bool(.true.))
      else
        call lp_peek_text(lp, s)
        call raise_line(p, "E103", "unexpected '" // s &
                        // "' in camera statement")
        return
      end if
    end do
    node = dyn_dict()
    call dset(node, "pos", dyn_null())  ! Python passes at=, not pos=
    call dset(node, "target", dget(props, "look"))
    call dset(node, "up", dget(props, "up"))
    call dset(node, "fov", dget(props, "fov"))
    call dset(node, "near", dget(props, "near"))
    call dset(node, "far", dget(props, "far"))
    call dset(node, "span", dyn_null())
    call dset(node, "at", dget(props, "at"))
    call dset(node, "position", dget(props, "at"))
    call dset(node, "look", dget(props, "look"))
    call dset(node, "props", props)
    call dset(node, "line", dyn_int(int(lp%no, int64)))
    call dyn_assign(stmt, node)
    has_stmt = .true.
  end subroutine parse_camera

  ! Parser._parse_light.
  subroutine parse_light(p, lp, stmt, has_stmt)
    type(parser_state), intent(inout) :: p
    type(line_cur), intent(inout) :: lp
    type(dyn), intent(out) :: stmt
    logical, intent(out) :: has_stmt
    character(:), allocatable :: w, s, kind, key
    type(dyn) :: direction, frm, position, target, intensity, colour
    type(dyn) :: extra, props, node, v
    type(str_set) :: seen
    logical :: hasw, has_dir, has_frm, has_pos, has_tgt, has_int, &
               has_col
    integer :: i
    has_stmt = .false.
    stmt = dyn_null()
    call lp_next(lp)  ! light
    kind = "directional"
    direction = dyn_null(); has_dir = .false.
    frm = dyn_null();       has_frm = .false.
    position = dyn_null();  has_pos = .false.
    target = dyn_null();    has_tgt = .false.
    intensity = dyn_null(); has_int = .false.
    colour = dyn_null();    has_col = .false.
    extra = dyn_dict()
    seen%n = 0
    do while (.not. lp_at_end(lp))
      call lp_peek_word(lp, w, hasw)
      if (hasw .and. (w == "directional" .or. w == "ambient" &
          .or. w == "point" .or. w == "spot")) then
        call lp_next(lp)
        kind = w
      else if (hasw .and. (w == "dir" .or. w == "direction")) then
        call lp_next(lp)
        call lp_dup(p, seen, "dir")
        if (p%le_set) return
        call lp_vec3(p, lp, direction)
        if (p%le_set) return
        has_dir = .true.
      else if (hasw .and. (w == "at" .or. w == "pos" &
               .or. w == "position")) then
        call lp_next(lp)
        call lp_dup(p, seen, "at")
        if (p%le_set) return
        call lp_vec3(p, lp, position)
        if (p%le_set) return
        has_pos = .true.
      else if (hasw .and. (w == "look" .or. w == "target" &
               .or. w == "look_at")) then
        call lp_next(lp)
        call lp_dup(p, seen, "look")
        if (p%le_set) return
        call lp_vec3(p, lp, target)
        if (p%le_set) return
        has_tgt = .true.
      else if (hasw .and. (w == "distance" .or. w == "decay" &
               .or. w == "angle" .or. w == "penumbra")) then
        call lp_next(lp)
        call lp_dup(p, seen, w)
        if (p%le_set) return
        call lp_number(p, lp, w, v)
        if (p%le_set) return
        call dset(extra, w, v)
      else if (hasw .and. w == "from") then
        call lp_next(lp)
        call lp_dup(p, seen, "from")
        if (p%le_set) return
        call lp_vec3(p, lp, frm)
        if (p%le_set) return
        has_frm = .true.
        has_dir = .true.
        ! direction = tuple(-v for v in frm)
        if (frm%kind == DYN_K_LIST .and. dyn_list_len(frm) == 3) then
          direction = vec3_of(dyn_neg(dyn_list_at(frm, 1)), &
                              dyn_neg(dyn_list_at(frm, 2)), &
                              dyn_neg(dyn_list_at(frm, 3)))
        else
          call dyn_assign(direction, frm)
        end if
      else if (hasw .and. (w == "intensity" .or. w == "strength")) then
        call lp_next(lp)
        call lp_dup(p, seen, "intensity")
        if (p%le_set) return
        call lp_number(p, lp, "intensity", intensity)
        if (p%le_set) return
        has_int = .true.
      else if (hasw .and. (w == "colour" .or. w == "color")) then
        call lp_next(lp)
        call lp_dup(p, seen, "colour")
        if (p%le_set) return
        call lp_colour(p, lp, colour)
        if (p%le_set) return
        has_col = .true.
      else if (lp_peek_kind(lp) == K_NUMBER) then
        call lp_dup(p, seen, "dir")
        if (p%le_set) return
        call lp_vec3(p, lp, direction)
        if (p%le_set) return
        has_dir = .true.
      else if (lp_peek_kind(lp) == K_COLOR .or. (hasw .and. w == "rgb") &
               .or. (hasw .and. in_list(w, COLOUR_WORDS))) then
        call lp_dup(p, seen, "colour")
        if (p%le_set) return
        call lp_colour(p, lp, colour)
        if (p%le_set) return
        has_col = .true.
      else
        call lp_peek_text(lp, s)
        call raise_line(p, "E103", "unexpected '" // s &
                        // "' in light statement")
        return
      end if
    end do
    if (.not. has_pos) then
      ! For point/spot, `from` names the position; for directional
      ! lights this preserves the v1 position=frm.
      call dyn_assign(position, frm)
      has_pos = has_frm
    end if
    props = dyn_dict()
    if (has_dir) then
      call dset(props, "direction", dyn_copy(direction))
      call dset(props, "dir", dyn_copy(direction))
    else
      call dset(props, "direction", dyn_null())
      call dset(props, "dir", dyn_null())
    end if
    if (has_frm) then
      call dset(props, "from", dyn_copy(frm))
    else
      call dset(props, "from", dyn_null())
    end if
    if (has_int) then
      call dset(props, "intensity", dyn_copy(intensity))
      call dset(props, "strength", dyn_copy(intensity))
    else
      call dset(props, "intensity", dyn_null())
      call dset(props, "strength", dyn_null())
    end if
    if (has_col) then
      call dset(props, "colour", dyn_copy(colour))
    else
      call dset(props, "colour", dyn_null())
    end if
    if (has_pos) then
      call dset(props, "at", dyn_copy(position))
      call dset(props, "position", dyn_copy(position))
    else
      call dset(props, "at", dyn_null())
      call dset(props, "position", dyn_null())
    end if
    if (has_tgt) then
      call dset(props, "look", dyn_copy(target))
      call dset(props, "target", dyn_copy(target))
    else
      call dset(props, "look", dyn_null())
      call dset(props, "target", dyn_null())
    end if
    do i = 1, dyn_dict_len(extra)
      key = dyn_dict_key_at(extra, i)
      v = dget(extra, key)
      call dset(props, key, v)
    end do
    node = dyn_dict()
    call dset(node, "kind", dyn_str(kind))
    if (has_dir) then
      call dset(node, "direction", dyn_copy(direction))
    else
      call dset(node, "direction", dyn_null())
    end if
    if (has_col) then
      call dset(node, "color", dyn_copy(colour))
    else
      call dset(node, "color", dyn_null())
    end if
    if (has_int) then
      call dset(node, "intensity", dyn_copy(intensity))
    else
      call dset(node, "intensity", dyn_null())
    end if
    call dset(node, "span", dyn_null())
    call dset(node, "type", dyn_str(kind))
    call dset(node, "mode", dyn_str(kind))
    if (has_dir) then
      call dset(node, "dir", dyn_copy(direction))
    else
      call dset(node, "dir", dyn_null())
    end if
    if (has_frm) then
      call dset(node, "from_", dyn_copy(frm))
    else
      call dset(node, "from_", dyn_null())
    end if
    if (has_pos) then
      call dset(node, "position", dyn_copy(position))
    else
      call dset(node, "position", dyn_null())
    end if
    if (has_tgt) then
      call dset(node, "target", dyn_copy(target))
    else
      call dset(node, "target", dyn_null())
    end if
    if (has_int) then
      call dset(node, "strength", dyn_copy(intensity))
    else
      call dset(node, "strength", dyn_null())
    end if
    if (has_col) then
      call dset(node, "colour", dyn_copy(colour))
    else
      call dset(node, "colour", dyn_null())
    end if
    call dset(node, "props", props)
    call dset(node, "line", dyn_int(int(lp%no, int64)))
    call dyn_assign(stmt, node)
    has_stmt = .true.
  end subroutine parse_light

  ! Parser._parse_group: header line + child lines up to 'end'.
  ! Header errors raise a line error (the caller reports them, as
  ! Python's parse_program handler does); child errors and the
  ! missing-'end' error are reported here directly.
  subroutine parse_group(p, header, lines, nlines, idx, stmt, has_stmt)
    type(parser_state), intent(inout) :: p
    type(line_rec), intent(in) :: header
    type(line_rec), intent(in) :: lines(:)
    integer, intent(in) :: nlines
    integer, intent(inout) :: idx
    type(dyn), intent(out) :: stmt
    logical, intent(out) :: has_stmt
    type(line_cur) :: lp
    type(line_rec) :: crec
    character(:), allocatable :: name, s, fw
    type(dyn) :: props, children, node, cstmt
    type(str_set) :: seen
    logical :: hasid, handled, chas
    integer :: nested
    has_stmt = .false.
    stmt = dyn_null()
    call make_cur(header%toks, header%no, lp)
    call lp_next(lp)  ! group
    call lp_ident(lp, name, hasid)
    if (.not. hasid) then
      call raise_line(p, "E401", "'group' needs a name")
      return
    end if
    props = dyn_dict()
    seen%n = 0
    do while (.not. lp_at_end(lp))
      call object_props(p, lp, props, seen, handled)
      if (p%le_set) return
      if (handled) cycle
      call lp_peek_text(lp, s)
      call raise_line(p, "E103", "unexpected '" // s &
                      // "' in group header")
      return
    end do
    children = dyn_list()
    nested = 0
    do while (idx <= nlines)
      crec = lines(idx)
      idx = idx + 1
      if (size(crec%toks) == 0) cycle
      if (allocated(crec%toks(1)%text)) then
        fw = word_norm(crec%toks(1)%text)
      else
        fw = ""
      end if
      if (fw == "end") then
        if (nested > 0) then
          nested = nested - 1
          cycle
        end if
        call group_node(name, props, children, header%no, node)
        call dyn_assign(stmt, node)
        has_stmt = .true.
        return
      end if
      if (fw == "group") then
        call parser_error(p, "E401", &
                          "groups cannot be nested (one level only)", &
                          crec%no, crec%toks(1)%col)
        if (p%stopped) return
        nested = nested + 1
        cycle
      end if
      if (nested > 0) cycle
      call parse_statement(p, crec%toks, crec%no, cstmt, chas)
      if (p%le_set) then
        call parser_error(p, p%le_code, p%le_msg, crec%no, &
                          crec%toks(1)%col)
        call clear_line_error(p)
        if (p%stopped) return
        cycle
      end if
      if (chas) call dyn_list_push(children, cstmt)
    end do
    call parser_error(p, "E401", "group '" // name &
                      // "' has no closing 'end'", header%no, 0)
    if (p%stopped) return
    call group_node(name, props, children, header%no, node)
    call dyn_assign(stmt, node)
    has_stmt = .true.
  end subroutine parse_group

  subroutine group_node(name, props, children, no, node)
    character(*), intent(in) :: name
    type(dyn), intent(in) :: props, children
    integer, intent(in) :: no
    type(dyn), intent(out) :: node
    node = dyn_dict()
    call dset(node, "name", dyn_str(name))
    call dset(node, "props", dyn_copy(props))
    call dset(node, "body", dyn_list())  ! dataclass default survives
    call dset(node, "span", dyn_null())
    call dset(node, "children", dyn_copy(children))
    call dset(node, "objects", dyn_copy(children))
    call dset(node, "statements", dyn_copy(children))
    call dset(node, "line", dyn_int(int(no, int64)))
  end subroutine group_node

  ! Parser._is_ring_repeat: `ring <count> <prim> ...` is the repeat
  ! form; anything else starting with 'ring' is the primitive.
  logical function is_ring_repeat(lp)
    type(line_cur), intent(in) :: lp
    character(:), allocatable :: s
    is_ring_repeat = .false.
    if (size(lp%toks) < 3) return
    if (lp%toks(2)%kind /= K_NUMBER) return
    if (allocated(lp%toks(3)%text)) then
      s = word_norm(lp%toks(3)%text)
    else
      s = ""
    end if
    is_ring_repeat = in_list(s, PRIMS)
  end function is_ring_repeat

  ! Parser._parse_statement dispatch (same order as Python).
  subroutine parse_statement(p, toks, no, stmt, has_stmt)
    type(parser_state), intent(inout) :: p
    type(itok), intent(in) :: toks(:)
    integer, intent(in) :: no
    type(dyn), intent(out) :: stmt
    logical, intent(out) :: has_stmt
    type(line_cur) :: lp
    character(:), allocatable :: first, sugg, msg, code
    type(str_builder) :: sb_msg
    logical :: hasw, found
    has_stmt = .false.
    stmt = dyn_null()
    call make_cur(toks, no, lp)
    call lp_peek_word(lp, first, hasw)
    if (.not. hasw) then
      call raise_line(p, "E103", "expected a statement")
      return
    end if
    if (first == "import") then
      ! v2.0 P3: 'import' is a real statement now, dispatched before
      ! the reserved-word rejection below (it stays in RESERVED_ALL
      ! so it still cannot be used as an object/name word elsewhere).
      call parse_import(p, lp, stmt, has_stmt)
      return
    end if
    if (in_list(first, RESERVED_ALL)) then
      if (in_list(first, RESERVED_SEC)) then
        code = "E820"
      else
        code = "E205"
      end if
      call raise_line(p, code, "'" // first // &
                      "' is reserved and not allowed in .f3d " &
                      // "(the language is declarative only)")
      return
    end if
    if (first == "scene") then
      call parse_scene(p, lp, stmt, has_stmt)
    else if (first == "camera") then
      call parse_camera(p, lp, stmt, has_stmt)
    else if (first == "light") then
      call parse_light(p, lp, stmt, has_stmt)
    else if (first == "ring") then
      ! Wave D ring primitive vs the repeat form: lookahead decides.
      if (is_ring_repeat(lp)) then
        call parse_repeat(p, lp, stmt, has_stmt)
      else
        call parse_object(p, lp, stmt, has_stmt)
      end if
    else if (in_list(first, PRIMS)) then
      call parse_object(p, lp, stmt, has_stmt)
    else if (first == "repeat" .or. first == "grid") then
      call parse_repeat(p, lp, stmt, has_stmt)
    else if (in_list(first, ANIM_VERBS) .or. first == "animate") then
      call parse_anim(p, lp, stmt, has_stmt)
    else if (first == "load") then
      call parse_load(p, lp, stmt, has_stmt)
    else if (first == "sprite") then
      call parse_sprite(p, lp, stmt, has_stmt)
    else if (first == "text") then
      call parse_text(p, lp, stmt, has_stmt)
    else if (first == "particles") then
      call parse_particles(p, lp, stmt, has_stmt)
    else if (first == "filter") then
      call parse_filter(p, lp, stmt, has_stmt)
    else if (first == "instance") then
      call parse_instance(p, lp, stmt, has_stmt)
    else if (first == "shader") then
      call parse_shader(p, lp, stmt, has_stmt)
    else if (first == "morph") then
      call parse_morph(p, lp, stmt, has_stmt)
    else if (first == "bone") then
      call parse_bone(p, lp, stmt, has_stmt)
    else if (first == "skin") then
      call parse_skin(p, lp, stmt, has_stmt)
    else if (first == "keys") then
      call parse_keys_header(p, lp, stmt, has_stmt)
    else if (first == "key") then
      call parse_key(p, lp, stmt, has_stmt)
    else if (first == "controls") then
      call parse_controls(p, lp, stmt, has_stmt)
    else if (first == "render" .or. first == "export") then
      call parse_output(p, lp, stmt, has_stmt)
    else if (first == "group") then
      call raise_line(p, "E401", "'group' must start a block")
    else
      call did_you_mean(first, STARTERS, sugg, found)
      call sb_init(sb_msg)
      call sb_add(sb_msg, "unknown word '")
      call sb_add(sb_msg, first)
      call sb_add(sb_msg, "'")
      if (found) then
        call sb_add(sb_msg, " -- did you mean '")
        call sb_add(sb_msg, sugg)
        call sb_add(sb_msg, "'?")
      end if
      msg = sb_text(sb_msg)
      call raise_line(p, "E104", msg)
    end if
  end subroutine parse_statement

  ! Parser._parse_anim.
  subroutine parse_anim(p, lp, stmt, has_stmt)
    type(parser_state), intent(inout) :: p
    type(line_cur), intent(inout) :: lp
    type(dyn), intent(out) :: stmt
    logical, intent(out) :: has_stmt
    character(:), allocatable :: first, s, w, w2, a
    type(dyn) :: target, props, node, v
    type(str_set) :: seen
    logical :: hasw, hasw2, hasid, target_null
    character(:), allocatable :: verb
    has_stmt = .false.
    stmt = dyn_null()
    call lp_next_text(lp, s)
    first = str_lower(s)
    verb = ""
    target = dyn_null()
    target_null = .true.
    if (first == "animate") then
      call lp_peek_word(lp, w, hasw)
      if (hasw .and. in_list(w, ANIM_VERBS)) then
        call lp_next_text(lp, s)
        verb = str_lower(s)
        ! 'animate spin it ...': the target may follow the motion.
        call lp_peek_word(lp, w2, hasw2)
        if (hasw2 .and. .not. in_list(w2, ANIM_PROP_WORDS) &
            .and. .not. in_list(w2, AXES) .and. w2 /= "loop" &
            .and. w2 /= "once" .and. w2 /= "forever" &
            .and. w2 /= "pingpong" .and. w2 /= "repeat") then
          call lp_next_text(lp, s)
          target = dyn_str(s)
          target_null = .false.
        end if
      else if (hasw) then
        call lp_next_text(lp, s)
        target = dyn_str(s)
        target_null = .false.
        call lp_peek_word(lp, w2, hasw2)
        if (hasw2 .and. in_list(w2, ANIM_VERBS)) then
          call lp_next_text(lp, s)
          verb = str_lower(s)
        else
          call raise_line(p, "E103", "'animate' needs a motion " &
                          // "such as spin, bob, pulse or move")
          return
        end if
      else
        call raise_line(p, "E101", &
                        "'animate' needs a target and a motion")
        return
      end if
    else
      verb = first
      call lp_peek_word(lp, w, hasw)
      if (hasw .and. .not. in_list(w, ANIM_PROP_WORDS) &
          .and. .not. in_list(w, AXES)) then
        call lp_next_text(lp, s)
        target = dyn_str(s)
        target_null = .false.
      end if
    end if
    props = dyn_dict()
    seen%n = 0
    do while (.not. lp_at_end(lp))
      call lp_peek_word(lp, w, hasw)
      if (hasw .and. w == "axis") then
        call lp_next(lp)
        call lp_dup(p, seen, "axis")
        if (p%le_set) return
        call lp_ident(lp, a, hasid)
        if (.not. hasid .or. .not. in_list(str_lower(a), AXES)) then
          call raise_line(p, "E103", "axis must be x, y or z")
          return
        end if
        call dset(props, "axis", dyn_str(str_lower(a)))
      else if (hasw .and. in_list(w, AXES) &
               .and. .not. set_has(seen, "axis")) then
        call lp_dup(p, seen, "axis")
        if (p%le_set) return
        call lp_next_text(lp, s)
        call dset(props, "axis", dyn_str(str_lower(s)))
        if (lp_peek_kind(lp) == K_NUMBER) then
          ! P03: a bare axis may be followed by a total amount.
          call lp_number(p, lp, "amount", v)
          if (p%le_set) return
          call dset(props, "amount", v)
        end if
      else if (hasw .and. (w == "speed" .or. w == "duration" &
               .or. w == "amplitude" .or. w == "distance" &
               .or. w == "amount")) then
        call lp_next(lp)
        call lp_dup(p, seen, w)
        if (p%le_set) return
        call lp_number(p, lp, w, v)
        if (p%le_set) return
        call dset(props, w, v)
      else if (hasw .and. w == "fps") then
        call lp_next(lp)
        call lp_dup(p, seen, "fps")
        if (p%le_set) return
        call lp_number(p, lp, "fps", v)
        if (p%le_set) return
        call dset(props, "fps", dyn_int(dyn_to_int(v)))
      else if (hasw .and. w == "ease") then
        call lp_next(lp)
        call lp_dup(p, seen, "ease")
        if (p%le_set) return
        call lp_ident(lp, s, hasid)
        if (hasid) then
          call dset(props, "ease", dyn_str(s))
        else
          call dset(props, "ease", dyn_null())
        end if
      else if (hasw .and. w == "loop") then
        call lp_next(lp)
        call lp_dup(p, seen, "loop")
        if (p%le_set) return
        call lp_peek_word(lp, w2, hasw2)
        if (hasw2 .and. in_list(w2, LOOP_WORDS)) then
          call lp_next_text(lp, s)
          call dset(props, "loop", dyn_str(str_lower(s)))
        else if (hasw2 .and. w2 == "repeat") then
          call lp_loop_repeat(p, lp, s)
          if (p%le_set) return
          call dset(props, "loop", dyn_str(s))
        else
          call dset(props, "loop", dyn_str("forever"))  ! bare 'loop'
        end if
      else if (hasw .and. in_list(w, LOOP_WORDS)) then
        call lp_dup(p, seen, "loop")
        if (p%le_set) return
        call lp_next_text(lp, s)
        call dset(props, "loop", dyn_str(str_lower(s)))
      else if (hasw .and. w == "repeat") then
        call lp_dup(p, seen, "loop")
        if (p%le_set) return
        call lp_loop_repeat(p, lp, s)
        if (p%le_set) return
        call dset(props, "loop", dyn_str(s))
      else
        call lp_peek_text(lp, s)
        call raise_line(p, "E103", "unexpected '" // s &
                        // "' in animation")
        return
      end if
    end do
    node = dyn_dict()
    call dset(node, "kind", dyn_str(verb))
    if (target_null) then
      call dset(node, "target", dyn_null())
    else
      call dset(node, "target", dyn_copy(target))
    end if
    call dset(node, "props", dyn_copy(props))
    call dset(node, "span", dyn_null())
    call dset(node, "verb", dyn_str(verb))
    call dset(node, "motion", dyn_str(verb))
    call dset(node, "action", dyn_str(verb))
    call dset(node, "line", dyn_int(int(lp%no, int64)))
    call dset(node, "axis", dget(props, "axis"))
    call dset(node, "speed", dget(props, "speed"))
    call dset(node, "duration", dget(props, "duration"))
    call dset(node, "fps", dget(props, "fps"))
    call dset(node, "ease", dget(props, "ease"))
    call dset(node, "loop", dget(props, "loop"))
    call dyn_assign(stmt, node)
    has_stmt = .true.
  end subroutine parse_anim

  ! Parser._parse_load.
  subroutine parse_load(p, lp, stmt, has_stmt)
    type(parser_state), intent(inout) :: p
    type(line_cur), intent(inout) :: lp
    type(dyn), intent(out) :: stmt
    logical, intent(out) :: has_stmt
    character(:), allocatable :: path, s, w, key
    type(dyn) :: name, props, node, v
    type(str_set) :: seen
    logical :: hasw, hasid, name_null, handled
    integer :: i
    has_stmt = .false.
    stmt = dyn_null()
    call lp_next(lp)  ! load
    if (lp_peek_kind(lp) == K_STRING) then
      call lp_next_text(lp, path)
    else if (.not. lp_at_end(lp)) then
      call lp_next_text(lp, path)
    else
      call raise_line(p, "E101", "'load' needs a quoted file path")
      return
    end if
    name = dyn_null()
    name_null = .true.
    props = dyn_dict()
    seen%n = 0
    do while (.not. lp_at_end(lp))
      call lp_peek_word(lp, w, hasw)
      if (hasw .and. w == "named") then
        call lp_next(lp)
        call lp_ident(lp, s, hasid)
        if (hasid) then
          name = dyn_str(s)
          name_null = .false.
        else
          name = dyn_null()
          name_null = .true.
        end if
        cycle
      end if
      call object_props(p, lp, props, seen, handled)
      if (p%le_set) return
      if (handled) cycle
      if (hasw .and. name_null &
          .and. .not. in_list(w, OBJECT_PROP_WORDS)) then
        call lp_next_text(lp, s)
        name = dyn_str(s)
        name_null = .false.
        cycle
      end if
      call lp_peek_text(lp, s)
      call raise_line(p, "E103", "unexpected '" // s &
                      // "' in load statement")
      return
    end do
    node = dyn_dict()
    call dset(node, "path", dyn_str(path))
    call dset(node, "name", dyn_copy(name))
    call dset(node, "props", dyn_copy(props))
    call dset(node, "span", dyn_null())
    call dset(node, "file", dyn_str(path))
    call dset(node, "line", dyn_int(int(lp%no, int64)))
    do i = 1, dyn_dict_len(props)
      key = dyn_dict_key_at(props, i)
      if (key == "name") cycle
      v = dget(props, key)
      call dset(node, key, v)
    end do
    call dyn_assign(stmt, node)
    has_stmt = .true.
  end subroutine parse_load

  ! v2.0 P3: import "parts/fin.f3d" as fin [props...]
  ! The trailing props are exactly a group header's props (the same
  ! object_props loop parse_group uses); desugar resolves the path,
  ! loads the part and expands it as a synthetic group with this
  ! name/props.  Node signature: "import_path" + "name" + "props".
  subroutine parse_import(p, lp, stmt, has_stmt)
    type(parser_state), intent(inout) :: p
    type(line_cur), intent(inout) :: lp
    type(dyn), intent(out) :: stmt
    logical, intent(out) :: has_stmt
    character(:), allocatable :: path, name, s, w
    type(dyn) :: props, node
    type(str_set) :: seen
    logical :: hasid, hasw, handled
    has_stmt = .false.
    stmt = dyn_null()
    call lp_next(lp)  ! import
    if (lp_peek_kind(lp) /= K_STRING) then
      call raise_line(p, "E103", &
                      "'import' needs a quoted file path")
      return
    end if
    call lp_next_text(lp, path)
    call lp_peek_word(lp, w, hasw)
    if (.not. hasw .or. w /= "as") then
      call raise_line(p, "E103", &
                      "'import' needs 'as <name>' after the path")
      return
    end if
    call lp_next(lp)  ! as
    call lp_ident(lp, name, hasid)
    if (.not. hasid) then
      call raise_line(p, "E103", &
                      "'import' needs a name after 'as'")
      return
    end if
    props = dyn_dict()
    seen%n = 0
    do while (.not. lp_at_end(lp))
      call object_props(p, lp, props, seen, handled)
      if (p%le_set) return
      if (handled) cycle
      call lp_peek_text(lp, s)
      call raise_line(p, "E103", "unexpected '" // s &
                      // "' in import statement")
      return
    end do
    node = dyn_dict()
    call dset(node, "import_path", dyn_str(path))
    call dset(node, "name", dyn_str(name))
    call dset(node, "props", dyn_copy(props))
    call dset(node, "span", dyn_null())
    call dset(node, "line", dyn_int(int(lp%no, int64)))
    call dyn_assign(stmt, node)
    has_stmt = .true.
  end subroutine parse_import

  ! ==================================================================
  ! Wave B/C/E statements (semantics live in the ext_* modules +
  ! validate; this layer only shapes the nodes, as in Python)
  ! ==================================================================

  ! Parser._waveb_named_props: shared [name] + object-prop tail for
  ! sprite/particles.  extra holds the extra numeric prop words.
  subroutine waveb_named_props(p, lp, extra, name, name_null, colour, &
                               has_colour, props)
    type(parser_state), intent(inout) :: p
    type(line_cur), intent(inout) :: lp
    character(16), intent(in) :: extra(:)
    type(dyn), intent(out) :: name, colour, props
    logical, intent(out) :: name_null, has_colour
    type(str_set) :: seen
    character(:), allocatable :: w, s
    type(dyn) :: v
    logical :: hasw, hasid, handled
    name = dyn_null()
    name_null = .true.
    colour = dyn_null()
    has_colour = .false.
    props = dyn_dict()
    seen%n = 0
    do while (.not. lp_at_end(lp))
      call lp_peek_word(lp, w, hasw)
      if (hasw .and. w == "named") then
        call lp_next(lp)
        call lp_ident(lp, s, hasid)
        if (hasid) then
          name = dyn_str(s)
          name_null = .false.
        else
          name = dyn_null()
          name_null = .true.
        end if
        cycle
      end if
      if (lp_peek_kind(lp) == K_COLOR .or. (hasw .and. w == "rgb")) then
        call lp_dup(p, seen, "colour")
        if (p%le_set) return
        call lp_colour(p, lp, colour)
        if (p%le_set) return
        has_colour = .true.
        cycle
      end if
      if (hasw .and. .not. in_list(w, OBJECT_PROP_WORDS) &
          .and. .not. in_list(w, extra) &
          .and. .not. in_list(w, RESERVED_ALL)) then
        if (in_list(w, COLOUR_WORDS)) then
          call lp_dup(p, seen, "colour")
          if (p%le_set) return
          call lp_colour(p, lp, colour)
          if (p%le_set) return
          has_colour = .true.
          cycle
        end if
        if (name_null) then
          call lp_next_text(lp, s)
          name = dyn_str(s)
          name_null = .false.
          cycle
        end if
        call raise_line(p, "E103", "unexpected word '" // w // "'")
        return
      end if
      exit
    end do
    do while (.not. lp_at_end(lp))
      call object_props(p, lp, props, seen, handled)
      if (p%le_set) return
      if (handled) cycle
      call lp_peek_word(lp, w, hasw)
      if (hasw .and. in_list(w, extra)) then
        call lp_next(lp)
        call lp_dup(p, seen, w)
        if (p%le_set) return
        call lp_number(p, lp, w, v)
        if (p%le_set) return
        call dset(props, w, v)
        cycle
      end if
      if (lp_peek_kind(lp) == K_COLOR .or. (hasw .and. w == "rgb") &
          .or. (hasw .and. in_list(w, COLOUR_WORDS))) then
        call lp_dup(p, seen, "colour")
        if (p%le_set) return
        call lp_colour(p, lp, colour)
        if (p%le_set) return
        has_colour = .true.
        cycle
      end if
      call lp_peek_text(lp, s)
      call raise_line(p, "E103", "unexpected '" // s // "'")
      return
    end do
    call adopt_colour(props, colour, has_colour)
  end subroutine waveb_named_props

  subroutine parse_sprite(p, lp, stmt, has_stmt)
    type(parser_state), intent(inout) :: p
    type(line_cur), intent(inout) :: lp
    type(dyn), intent(out) :: stmt
    logical, intent(out) :: has_stmt
    character(16) :: extra(0)
    type(dyn) :: name, colour, props, node
    logical :: name_null, has_colour
    has_stmt = .false.
    stmt = dyn_null()
    call lp_next(lp)  ! sprite
    call waveb_named_props(p, lp, extra, name, name_null, colour, &
                           has_colour, props)
    if (p%le_set) return
    node = dyn_dict()
    call dset(node, "name", dyn_copy(name))
    if (has_colour) then
      call dset(node, "colour", dyn_copy(colour))
      call dset(node, "color", dyn_copy(colour))
    else
      call dset(node, "colour", dyn_null())
      call dset(node, "color", dyn_null())
    end if
    call dset(node, "props", props)
    call dset(node, "line", dyn_int(int(lp%no, int64)))
    call dset(node, "span", dyn_null())
    call dyn_assign(stmt, node)
    has_stmt = .true.
  end subroutine parse_sprite

  subroutine parse_particles(p, lp, stmt, has_stmt)
    type(parser_state), intent(inout) :: p
    type(line_cur), intent(inout) :: lp
    type(dyn), intent(out) :: stmt
    logical, intent(out) :: has_stmt
    character(16) :: extra(6)
    type(dyn) :: name, colour, props, node, v
    logical :: name_null, has_colour
    has_stmt = .false.
    stmt = dyn_null()
    extra = [character(16) :: "count", "life", "speed", "spread", &
             "gravity", "seed"]
    call lp_next(lp)  ! particles
    call waveb_named_props(p, lp, extra, name, name_null, colour, &
                           has_colour, props)
    if (p%le_set) return
    if (dyn_dict_has(props, "count")) then
      v = dget(props, "count")
      call dset(props, "count", dyn_int(dyn_to_int(v)))
    end if
    if (dyn_dict_has(props, "seed")) then
      v = dget(props, "seed")
      call dset(props, "seed", dyn_int(dyn_to_int(v)))
    end if
    node = dyn_dict()
    call dset(node, "name", dyn_copy(name))
    if (has_colour) then
      call dset(node, "colour", dyn_copy(colour))
      call dset(node, "color", dyn_copy(colour))
    else
      call dset(node, "colour", dyn_null())
      call dset(node, "color", dyn_null())
    end if
    call dset(node, "props", props)
    call dset(node, "line", dyn_int(int(lp%no, int64)))
    call dset(node, "span", dyn_null())
    call dyn_assign(stmt, node)
    has_stmt = .true.
  end subroutine parse_particles

  subroutine parse_filter(p, lp, stmt, has_stmt)
    type(parser_state), intent(inout) :: p
    type(line_cur), intent(inout) :: lp
    type(dyn), intent(out) :: stmt
    logical, intent(out) :: has_stmt
    character(:), allocatable :: name, s
    type(dyn) :: amount, props, node
    logical :: hasid, has_amount
    has_stmt = .false.
    stmt = dyn_null()
    call lp_next(lp)  ! filter
    call lp_ident(lp, name, hasid)
    if (.not. hasid) then
      call raise_line(p, "E101", "'filter' needs a filter name, " &
                      // "like: filter blur 1")
      return
    end if
    amount = dyn_null()
    has_amount = .false.
    if (.not. lp_at_end(lp)) then
      call lp_number(p, lp, "filter amount", amount)
      if (p%le_set) return
      has_amount = .true.
    end if
    if (.not. lp_at_end(lp)) then
      call lp_peek_text(lp, s)
      call raise_line(p, "E103", "unexpected '" // s &
                      // "' in filter statement")
      return
    end if
    props = dyn_dict()
    call dset(props, "name", dyn_str(str_lower(name)))
    if (has_amount) call dset(props, "amount", dyn_copy(amount))
    node = dyn_dict()
    call dset(node, "name", dyn_str(str_lower(name)))
    if (has_amount) then
      call dset(node, "amount", amount)
    else
      call dset(node, "amount", dyn_null())
    end if
    call dset(node, "props", props)
    call dset(node, "line", dyn_int(int(lp%no, int64)))
    call dset(node, "span", dyn_null())
    call dyn_assign(stmt, node)
    has_stmt = .true.
  end subroutine parse_filter

  subroutine parse_shader(p, lp, stmt, has_stmt)
    type(parser_state), intent(inout) :: p
    type(line_cur), intent(inout) :: lp
    type(dyn), intent(out) :: stmt
    logical, intent(out) :: has_stmt
    character(:), allocatable :: name, expr, s, w
    type(dyn) :: props, node
    logical :: hasid, hasw
    has_stmt = .false.
    stmt = dyn_null()
    call lp_next(lp)  ! shader
    call lp_ident(lp, name, hasid)
    if (.not. hasid) then
      call raise_line(p, "E101", "'shader' needs a name, like: " &
                      // 'shader glow expr "c * ndl"')
      return
    end if
    call lp_peek_word(lp, w, hasw)
    if (.not. hasw .or. w /= "expr") then
      call raise_line(p, "E103", "'shader " // name &
                      // "' expects 'expr' before the quoted expression")
      return
    end if
    call lp_next(lp)  ! expr
    if (lp_peek_kind(lp) /= K_STRING) then
      call raise_line(p, "E101", "'shader " // name &
                      // "' needs a quoted expression, like: shader " &
                      // name // ' expr "c * 0.5"')
      return
    end if
    call lp_next_text(lp, expr)
    if (.not. lp_at_end(lp)) then
      call lp_peek_text(lp, s)
      call raise_line(p, "E103", "unexpected '" // s &
                      // "' in shader statement")
      return
    end if
    props = dyn_dict()
    call dset(props, "name", dyn_str(str_lower(name)))
    call dset(props, "expr", dyn_str(expr))
    node = dyn_dict()
    call dset(node, "name", dyn_str(str_lower(name)))
    call dset(node, "expr", dyn_str(expr))
    call dset(node, "props", props)
    call dset(node, "line", dyn_int(int(lp%no, int64)))
    call dset(node, "span", dyn_null())
    call dyn_assign(stmt, node)
    has_stmt = .true.
  end subroutine parse_shader

  subroutine parse_morph(p, lp, stmt, has_stmt)
    type(parser_state), intent(inout) :: p
    type(line_cur), intent(inout) :: lp
    type(dyn), intent(out) :: stmt
    logical, intent(out) :: has_stmt
    character(:), allocatable :: target, kind, s
    type(dyn) :: factor, props, node
    logical :: hasid
    has_stmt = .false.
    stmt = dyn_null()
    call lp_next(lp)  ! morph
    call lp_ident(lp, target, hasid)
    if (.not. hasid) then
      call raise_line(p, "E101", "'morph' needs an object name, " &
                      // "like: morph hero bulge 0.5")
      return
    end if
    call lp_ident(lp, kind, hasid)
    if (.not. hasid) then
      call raise_line(p, "E101", "'morph " // target &
                      // "' needs a kind: bulge, taper or squash")
      return
    end if
    if (lp_at_end(lp)) then
      call raise_line(p, "E101", "'morph " // target // " " // kind &
                      // "' needs a factor, like: morph " // target &
                      // " " // kind // " 0.5")
      return
    end if
    call lp_number(p, lp, "morph factor", factor)
    if (p%le_set) return
    if (.not. lp_at_end(lp)) then
      call lp_peek_text(lp, s)
      call raise_line(p, "E103", "unexpected '" // s &
                      // "' in morph statement")
      return
    end if
    props = dyn_dict()
    call dset(props, "target", dyn_str(target))
    call dset(props, "kind", dyn_str(str_lower(kind)))
    call dset(props, "factor", dyn_copy(factor))
    node = dyn_dict()
    call dset(node, "target", dyn_str(target))
    call dset(node, "kind", dyn_str(str_lower(kind)))
    call dset(node, "factor", factor)
    call dset(node, "props", props)
    call dset(node, "line", dyn_int(int(lp%no, int64)))
    call dset(node, "span", dyn_null())
    call dyn_assign(stmt, node)
    has_stmt = .true.
  end subroutine parse_morph

  subroutine parse_bone(p, lp, stmt, has_stmt)
    type(parser_state), intent(inout) :: p
    type(line_cur), intent(inout) :: lp
    type(dyn), intent(out) :: stmt
    logical, intent(out) :: has_stmt
    character(:), allocatable :: name, w, s, key
    type(dyn) :: props, node, v
    type(str_set) :: seen
    logical :: hasid, hasw
    integer :: i
    has_stmt = .false.
    stmt = dyn_null()
    call lp_next(lp)  ! bone
    call lp_ident(lp, name, hasid)
    if (.not. hasid) then
      call raise_line(p, "E101", "'bone' needs a name, like: " &
                      // "bone arm at 1,0,0 rotate 0,0,45")
      return
    end if
    props = dyn_dict()
    call dset(props, "name", dyn_str(name))
    seen%n = 0
    do while (.not. lp_at_end(lp))
      call lp_peek_word(lp, w, hasw)
      if (hasw .and. (w == "at" .or. w == "pos" &
          .or. w == "position")) then
        call lp_next(lp)
        call lp_dup(p, seen, "at")
        if (p%le_set) return
        call lp_vec3(p, lp, v)
        if (p%le_set) return
        call dset(props, "at", v)
      else if (hasw .and. (w == "rotate" .or. w == "rot")) then
        call lp_next(lp)
        call lp_dup(p, seen, "rotate")
        if (p%le_set) return
        call lp_vec3(p, lp, v)
        if (p%le_set) return
        call dset(props, "rotate", v)
      else if (hasw .and. w == "radius") then
        call lp_next(lp)
        call lp_dup(p, seen, "radius")
        if (p%le_set) return
        call lp_number(p, lp, "bone radius", v)
        if (p%le_set) return
        call dset(props, "radius", v)
      else
        call lp_peek_text(lp, s)
        call raise_line(p, "E103", "unexpected '" // s &
                        // "' in bone statement")
        return
      end if
    end do
    node = dyn_dict()
    call dset(node, "name", dyn_str(name))
    call dset(node, "props", dyn_copy(props))
    call dset(node, "line", dyn_int(int(lp%no, int64)))
    call dset(node, "span", dyn_null())
    do i = 1, dyn_dict_len(props)
      key = dyn_dict_key_at(props, i)
      if (key == "name") cycle
      v = dget(props, key)
      call dset(node, key, v)
    end do
    call dyn_assign(stmt, node)
    has_stmt = .true.
  end subroutine parse_bone

  subroutine parse_skin(p, lp, stmt, has_stmt)
    type(parser_state), intent(inout) :: p
    type(line_cur), intent(inout) :: lp
    type(dyn), intent(out) :: stmt
    logical, intent(out) :: has_stmt
    character(:), allocatable :: target, bone, s
    type(dyn) :: props, node
    logical :: hasid
    has_stmt = .false.
    stmt = dyn_null()
    call lp_next(lp)  ! skin
    call lp_ident(lp, target, hasid)
    if (.not. hasid) then
      call raise_line(p, "E101", "'skin' needs an object name, " &
                      // "like: skin hero arm")
      return
    end if
    call lp_ident(lp, bone, hasid)
    if (.not. hasid) then
      call raise_line(p, "E101", "'skin " // target &
                      // "' needs a bone name, like: skin " // target &
                      // " arm")
      return
    end if
    if (.not. lp_at_end(lp)) then
      call lp_peek_text(lp, s)
      call raise_line(p, "E103", "unexpected '" // s &
                      // "' in skin statement")
      return
    end if
    props = dyn_dict()
    call dset(props, "target", dyn_str(target))
    call dset(props, "bone", dyn_str(bone))
    node = dyn_dict()
    call dset(node, "target", dyn_str(target))
    call dset(node, "bone", dyn_str(bone))
    call dset(node, "props", props)
    call dset(node, "line", dyn_int(int(lp%no, int64)))
    call dset(node, "span", dyn_null())
    call dyn_assign(stmt, node)
    has_stmt = .true.
  end subroutine parse_skin

  subroutine parse_instance(p, lp, stmt, has_stmt)
    type(parser_state), intent(inout) :: p
    type(line_cur), intent(inout) :: lp
    type(dyn), intent(out) :: stmt
    logical, intent(out) :: has_stmt
    character(:), allocatable :: new_name, source, w, s
    type(dyn) :: props, node
    type(str_set) :: seen
    logical :: hasid, hasw, handled
    has_stmt = .false.
    stmt = dyn_null()
    call lp_next(lp)  ! instance
    call lp_ident(lp, new_name, hasid)
    if (.not. hasid) then
      call raise_line(p, "E101", "'instance' needs a name for the " &
                      // "new object, like: instance c2 of cube1 " &
                      // "at 2,0,0")
      return
    end if
    call lp_peek_word(lp, w, hasw)
    if (.not. hasw .or. w /= "of") then
      call raise_line(p, "E103", "'instance' expects 'of' after " &
                      // "the new name")
      return
    end if
    call lp_next(lp)  ! of
    call lp_ident(lp, source, hasid)
    if (.not. hasid) then
      call raise_line(p, "E101", "'instance' needs the name of " &
                      // "the object it copies after 'of'")
      return
    end if
    props = dyn_dict()
    seen%n = 0
    do while (.not. lp_at_end(lp))
      call object_props(p, lp, props, seen, handled)
      if (p%le_set) return
      if (handled) cycle
      call lp_peek_text(lp, s)
      call raise_line(p, "E103", "unexpected '" // s &
                      // "' in instance statement")
      return
    end do
    call dset(props, "source", dyn_str(source))
    node = dyn_dict()
    call dset(node, "name", dyn_str(new_name))
    call dset(node, "source", dyn_str(source))
    call dset(node, "props", props)
    call dset(node, "line", dyn_int(int(lp%no, int64)))
    call dset(node, "span", dyn_null())
    call dyn_assign(stmt, node)
    has_stmt = .true.
  end subroutine parse_instance

  subroutine parse_text(p, lp, stmt, has_stmt)
    type(parser_state), intent(inout) :: p
    type(line_cur), intent(inout) :: lp
    type(dyn), intent(out) :: stmt
    logical, intent(out) :: has_stmt
    character(:), allocatable :: content, w, s
    type(dyn) :: name, colour, props, node
    type(str_set) :: seen
    logical :: hasw, has_name, has_colour, handled
    has_stmt = .false.
    stmt = dyn_null()
    call lp_next(lp)  ! text
    name = dyn_null()
    has_name = .false.
    ! Optional name: a word directly followed by the quoted string.
    if (lp_peek_kind(lp) == K_WORD .and. lp%i + 1 <= size(lp%toks)) then
      if (lp%toks(lp%i + 1)%kind == K_STRING) then
        call lp_next_text(lp, s)
        name = dyn_str(s)
        has_name = .true.
      end if
    end if
    if (lp_peek_kind(lp) /= K_STRING) then
      call raise_line(p, "E101", "'text' needs a quoted string, " &
                      // 'like: text "HELLO"')
      return
    end if
    call lp_next_text(lp, content)
    colour = dyn_null()
    has_colour = .false.
    props = dyn_dict()
    seen%n = 0
    do while (.not. lp_at_end(lp))
      call object_props(p, lp, props, seen, handled)
      if (p%le_set) return
      if (handled) cycle
      call lp_peek_word(lp, w, hasw)
      if (lp_peek_kind(lp) == K_COLOR .or. (hasw .and. w == "rgb") &
          .or. (hasw .and. in_list(w, COLOUR_WORDS))) then
        call lp_dup(p, seen, "colour")
        if (p%le_set) return
        call lp_colour(p, lp, colour)
        if (p%le_set) return
        has_colour = .true.
        cycle
      end if
      call lp_peek_text(lp, s)
      call raise_line(p, "E103", "unexpected '" // s &
                      // "' in text statement")
      return
    end do
    call adopt_colour(props, colour, has_colour)
    call dset(props, "content", dyn_str(content))
    node = dyn_dict()
    if (has_name) then
      call dset(node, "name", dyn_copy(name))
    else
      call dset(node, "name", dyn_null())
    end if
    call dset(node, "content", dyn_str(content))
    if (has_colour) then
      call dset(node, "colour", dyn_copy(colour))
      call dset(node, "color", dyn_copy(colour))
    else
      call dset(node, "colour", dyn_null())
      call dset(node, "color", dyn_null())
    end if
    call dset(node, "props", props)
    call dset(node, "line", dyn_int(int(lp%no, int64)))
    call dset(node, "span", dyn_null())
    call dyn_assign(stmt, node)
    has_stmt = .true.
  end subroutine parse_text

  subroutine parse_keys_header(p, lp, stmt, has_stmt)
    type(parser_state), intent(inout) :: p
    type(line_cur), intent(inout) :: lp
    type(dyn), intent(out) :: stmt
    logical, intent(out) :: has_stmt
    character(:), allocatable :: target, w, v, s
    type(dyn) :: duration, loopv, fpsv, props, node
    type(str_set) :: seen
    logical :: hasid, hasw, hasv, has_duration, has_loop, has_fps
    has_stmt = .false.
    stmt = dyn_null()
    call lp_next(lp)  ! keys
    call lp_ident(lp, target, hasid)
    if (.not. hasid) then
      call raise_line(p, "E101", "'keys' needs the name of the " &
                      // "object it animates")
      return
    end if
    duration = dyn_null()
    has_duration = .false.
    loopv = dyn_null()
    has_loop = .false.
    fpsv = dyn_null()
    has_fps = .false.
    seen%n = 0
    do while (.not. lp_at_end(lp))
      call lp_peek_word(lp, w, hasw)
      if (hasw .and. w == "duration") then
        call lp_next(lp)
        call lp_dup(p, seen, "duration")
        if (p%le_set) return
        call lp_number(p, lp, "duration", duration)
        if (p%le_set) return
        has_duration = .true.
      else if (hasw .and. w == "fps") then
        ! v3.0 Phase 5 (M3): per-clip fps for this track.
        call lp_next(lp)
        call lp_dup(p, seen, "fps")
        if (p%le_set) return
        call lp_number(p, lp, "fps", fpsv)
        if (p%le_set) return
        has_fps = .true.
      else if (hasw .and. w == "loop") then
        call lp_next(lp)
        call lp_dup(p, seen, "loop")
        if (p%le_set) return
        call lp_peek_word(lp, v, hasv)
        if (hasv .and. in_list(v, LOOP_WORDS)) then
          call lp_next_text(lp, s)
          loopv = dyn_str(str_lower(s))
          has_loop = .true.
        else
          call raise_line(p, "E103", "loop must be once, forever " &
                          // "or pingpong")
          return
        end if
      else if (hasw .and. in_list(w, LOOP_WORDS)) then
        call lp_dup(p, seen, "loop")
        if (p%le_set) return
        call lp_next_text(lp, s)
        loopv = dyn_str(str_lower(s))
        has_loop = .true.
      else
        call lp_peek_text(lp, s)
        call raise_line(p, "E103", "unexpected '" // s &
                        // "' in keys statement")
        return
      end if
    end do
    props = dyn_dict()
    if (has_duration) call dset(props, "duration", dyn_copy(duration))
    if (has_loop) call dset(props, "loop", dyn_copy(loopv))
    if (has_fps) call dset(props, "fps", dyn_copy(fpsv))
    call dset(props, "target", dyn_str(target))
    node = dyn_dict()
    call dset(node, "target", dyn_str(target))
    if (has_fps) call dset(node, "fps", fpsv)
    if (has_duration) then
      call dset(node, "duration", duration)
    else
      call dset(node, "duration", dyn_null())
    end if
    if (has_loop) then
      call dset(node, "loop", loopv)
    else
      call dset(node, "loop", dyn_null())
    end if
    call dset(node, "props", props)
    call dset(node, "line", dyn_int(int(lp%no, int64)))
    call dset(node, "span", dyn_null())
    call dyn_assign(stmt, node)
    has_stmt = .true.
  end subroutine parse_keys_header

  subroutine parse_key(p, lp, stmt, has_stmt)
    type(parser_state), intent(inout) :: p
    type(line_cur), intent(inout) :: lp
    type(dyn), intent(out) :: stmt
    logical, intent(out) :: has_stmt
    character(:), allocatable :: target, w, s
    type(dyn) :: timev, pos, rot, scale, ease, props, node
    type(str_set) :: seen
    logical :: hasid, hasw, has_time
    has_stmt = .false.
    stmt = dyn_null()
    call lp_next(lp)  ! key
    call lp_ident(lp, target, hasid)
    if (.not. hasid) then
      call raise_line(p, "E101", "'key' needs the name of the " &
                      // "object it animates")
      return
    end if
    timev = dyn_null();  has_time = .false.
    pos = dyn_null()
    rot = dyn_null()
    scale = dyn_null()
    ease = dyn_null()
    seen%n = 0
    do while (.not. lp_at_end(lp))
      call lp_peek_word(lp, w, hasw)
      if (hasw .and. w == "at") then
        call lp_next(lp)
        call lp_dup(p, seen, "at")
        if (p%le_set) return
        call lp_number(p, lp, "key time", timev)
        if (p%le_set) return
        has_time = .true.
      else if (hasw .and. (w == "pos" .or. w == "position")) then
        call lp_next(lp)
        call lp_dup(p, seen, "pos")
        if (p%le_set) return
        call lp_vec3(p, lp, pos)
        if (p%le_set) return
      else if (hasw .and. (w == "rot" .or. w == "rotate")) then
        call lp_next(lp)
        call lp_dup(p, seen, "rot")
        if (p%le_set) return
        call lp_vec3(p, lp, rot)
        if (p%le_set) return
      else if (hasw .and. w == "scale") then
        call lp_next(lp)
        call lp_dup(p, seen, "scale")
        if (p%le_set) return
        call lp_number(p, lp, "scale", scale)
        if (p%le_set) return
      else if (hasw .and. w == "ease") then
        call lp_next(lp)
        call lp_dup(p, seen, "ease")
        if (p%le_set) return
        call lp_ident(lp, s, hasid)
        if (hasid) then
          ease = dyn_str(s)
        else
          ease = dyn_null()
        end if
      else
        call lp_peek_text(lp, s)
        call raise_line(p, "E103", "unexpected '" // s &
                        // "' in key statement")
        return
      end if
    end do
    if (.not. has_time) then
      call raise_line(p, "E101", "'key' needs a time: key " // target &
                      // " at 0 ...")
      return
    end if
    props = dyn_dict()
    call dset(props, "target", dyn_str(target))
    call dset(props, "time", dyn_copy(timev))
    call dset(props, "pos", dyn_copy(pos))
    call dset(props, "rot", dyn_copy(rot))
    call dset(props, "scale", dyn_copy(scale))
    call dset(props, "ease", dyn_copy(ease))
    node = dyn_dict()
    call dset(node, "target", dyn_str(target))
    call dset(node, "time", timev)
    call dset(node, "pos", pos)
    call dset(node, "rot", rot)
    call dset(node, "scale", scale)
    call dset(node, "ease", ease)
    call dset(node, "props", props)
    call dset(node, "line", dyn_int(int(lp%no, int64)))
    call dset(node, "span", dyn_null())
    call dyn_assign(stmt, node)
    has_stmt = .true.
  end subroutine parse_key

  ! Parser._parse_repeat.
  subroutine parse_repeat(p, lp, stmt, has_stmt)
    type(parser_state), intent(inout) :: p
    type(line_cur), intent(inout) :: lp
    type(dyn), intent(out) :: stmt
    logical, intent(out) :: has_stmt
    character(:), allocatable :: kind, s, w
    type(dyn) :: obj, node, v
    integer(int64) :: count, rows, cols
    logical :: hasw, is_grid, ohas
    has_stmt = .false.
    stmt = dyn_null()
    call lp_next_text(lp, s)
    kind = str_lower(s)
    count = 0_int64
    rows = 0_int64; cols = 0_int64
    is_grid = .false.
    if (kind == "repeat") then
      call lp_number(p, lp, "repeat count", v)
      if (p%le_set) return
      count = dyn_to_int(v)
    else if (kind == "ring") then
      call lp_number(p, lp, "ring count", v)
      if (p%le_set) return
      count = dyn_to_int(v)
    else  ! grid
      is_grid = .true.
      call lp_grid_size(p, lp, rows, cols)
      if (p%le_set) return
      count = rows * cols
    end if
    if (lp_at_end(lp)) then
      call raise_line(p, "E101", "'" // kind &
                      // "' needs an object to repeat")
      return
    end if
    call lp_peek_word(lp, w, hasw)
    if (.not. hasw .or. .not. in_list(w, PRIMS)) then
      call lp_peek_text(lp, s)
      call raise_line(p, "E103", "'" // kind &
                      // "' must be followed by an object, got '" &
                      // s // "'")
      return
    end if
    call parse_object(p, lp, obj, ohas)
    if (p%le_set) return
    node = dyn_dict()
    call dset(node, "mode", dyn_str(kind))
    call dset(node, "a", dyn_int(0_int64))  ! dataclass default survives
    call dset(node, "b", dyn_null())
    call dset(node, "obj", dyn_copy(obj))
    call dset(node, "span", dyn_null())
    call dset(node, "kind", dyn_str(kind))
    call dset(node, "count", dyn_int(count))
    if (is_grid) then
      call dset(node, "rows", dyn_int(rows))
      call dset(node, "cols", dyn_int(cols))
      call dset(node, "grid", pair_of(rows, cols))
    else
      call dset(node, "rows", dyn_null())
      call dset(node, "cols", dyn_null())
      call dset(node, "grid", dyn_null())
    end if
    call dset(node, "object", dyn_copy(obj))
    call dset(node, "props", dyn_dict())
    call dset(node, "line", dyn_int(int(lp%no, int64)))
    call dyn_assign(stmt, node)
    has_stmt = .true.
  end subroutine parse_repeat

  ! Parser._parse_controls.
  subroutine parse_controls(p, lp, stmt, has_stmt)
    type(parser_state), intent(inout) :: p
    type(line_cur), intent(inout) :: lp
    type(dyn), intent(out) :: stmt
    logical, intent(out) :: has_stmt
    character(:), allocatable :: mode, w, s
    type(dyn) :: props, node, v
    type(str_set) :: seen
    logical :: hasid, hasw
    has_stmt = .false.
    stmt = dyn_null()
    call lp_next(lp)  ! controls
    call lp_ident(lp, mode, hasid)
    if (hasid) mode = str_lower(mode)
    if (.not. hasid .or. (mode /= "orbit" .and. mode /= "none")) then
      call raise_line(p, "E103", &
                      "controls must be 'orbit' or 'none'")
      return
    end if
    props = dyn_dict()
    call dset(props, "autorotate", dyn_bool(.false.))
    seen%n = 0
    do while (.not. lp_at_end(lp))
      call lp_peek_word(lp, w, hasw)
      if (hasw .and. w == "autorotate") then
        call lp_next(lp)
        call dset(props, "autorotate", dyn_bool(.true.))
      else if (hasw .and. (w == "min" .or. w == "max")) then
        call lp_next(lp)
        call lp_dup(p, seen, w)
        if (p%le_set) return
        call lp_number(p, lp, w, v)
        if (p%le_set) return
        call dset(props, w, v)
      else
        call lp_peek_text(lp, s)
        call raise_line(p, "E103", "unexpected '" // s &
                        // "' in controls")
        return
      end if
    end do
    node = dyn_dict()
    call dset(node, "kind", dyn_str("orbit"))  ! dataclass default
    call dset(node, "props", dyn_copy(props))
    call dset(node, "span", dyn_null())
    call dset(node, "mode", dyn_str(mode))
    call dset(node, "type", dyn_str(mode))
    call dset(node, "autorotate", dget(props, "autorotate"))
    call dset(node, "min", dget(props, "min"))
    call dset(node, "max", dget(props, "max"))
    call dset(node, "line", dyn_int(int(lp%no, int64)))
    call dyn_assign(stmt, node)
    has_stmt = .true.
  end subroutine parse_controls

  ! Parser._parse_output (render / export).
  subroutine parse_output(p, lp, stmt, has_stmt)
    type(parser_state), intent(inout) :: p
    type(line_cur), intent(inout) :: lp
    type(dyn), intent(out) :: stmt
    logical, intent(out) :: has_stmt
    character(:), allocatable :: kind, s, w, fmt
    type(dyn) :: path, props, node, v
    type(str_set) :: seen
    integer(int64) :: sw, sh
    logical :: hasw, hasid, has_fmt, path_null, has_size, still
    has_stmt = .false.
    stmt = dyn_null()
    call lp_next_text(lp, s)
    kind = str_lower(s)
    fmt = ""
    has_fmt = .false.
    path = dyn_null()
    path_null = .true.
    has_size = .false.
    sw = 0_int64; sh = 0_int64
    still = .false.
    props = dyn_dict()
    seen%n = 0
    if (kind == "export") then
      call lp_ident(lp, s, hasid)
      if (.not. hasid .or. (str_lower(s) /= "json" &
          .and. str_lower(s) /= "obj" .and. str_lower(s) /= "html")) then
        call raise_line(p, "E103", "export needs a format: json, " &
                        // "obj or html")
        return
      end if
      fmt = str_lower(s)
      has_fmt = .true.
      call dset(props, "format", dyn_str(fmt))
      if (lp_peek_kind(lp) == K_STRING) then
        call lp_next_text(lp, s)
        path = dyn_str(s)
        path_null = .false.
      else
        call lp_peek_word(lp, w, hasw)
        if (hasw .and. w == "to") then
          call lp_next(lp)
          call lp_next_text(lp, s)
          path = dyn_str(s)
          path_null = .false.
        end if
      end if
    end if
    do while (.not. lp_at_end(lp))
      call lp_peek_word(lp, w, hasw)
      if (lp_peek_kind(lp) == K_STRING .and. path_null) then
        call lp_next_text(lp, s)
        path = dyn_str(s)
        path_null = .false.
      else if (hasw .and. w == "to") then
        call lp_next(lp)
        call lp_next_text(lp, s)
        path = dyn_str(s)
        path_null = .false.
      else if (hasw .and. w == "size") then
        call lp_next(lp)
        call lp_dup(p, seen, "size")
        if (p%le_set) return
        call lp_size(p, lp, sw, sh)
        if (p%le_set) return
        has_size = .true.
      else if (lp_peek_size_token(lp)) then
        call lp_dup(p, seen, "size")
        if (p%le_set) return
        call lp_size(p, lp, sw, sh)
        if (p%le_set) return
        has_size = .true.
      else if (hasw .and. w == "still") then
        call lp_next(lp)
        still = .true.
      else if (hasw .and. (w == "frames" .or. w == "fps" &
               .or. w == "duration")) then
        call lp_next(lp)
        call lp_dup(p, seen, w)
        if (p%le_set) return
        call lp_number(p, lp, w, v)
        if (p%le_set) return
        call dset(props, w, v)
      else
        call lp_peek_text(lp, s)
        call raise_line(p, "E103", "unexpected '" // s // "' in " &
                        // kind // " statement")
        return
      end if
    end do
    if (has_size) call dset(props, "size", pair_of(sw, sh))
    if (.not. path_null) call dset(props, "path", dyn_copy(path))
    node = dyn_dict()
    call dset(node, "kind", dyn_str(kind))
    if (path_null) then
      call dset(node, "path", dyn_null())
    else
      call dset(node, "path", dyn_copy(path))
    end if
    if (has_fmt) then
      call dset(node, "format", dyn_str(fmt))
    else
      call dset(node, "format", dyn_null())
    end if
    if (has_size) then
      call dset(node, "width", dyn_int(sw))
      call dset(node, "height", dyn_int(sh))
    else
      call dset(node, "width", dyn_null())
      call dset(node, "height", dyn_null())
    end if
    call dset(node, "span", dyn_null())
    call dset(node, "mode", dyn_str(kind))
    if (has_fmt) then
      call dset(node, "fmt", dyn_str(fmt))
    else
      call dset(node, "fmt", dyn_null())
    end if
    if (path_null) then
      call dset(node, "file", dyn_null())
    else
      call dset(node, "file", dyn_copy(path))
    end if
    if (has_size) then
      call dset(node, "size", pair_of(sw, sh))
    else
      call dset(node, "size", dyn_null())
    end if
    call dset(node, "still", dyn_bool(still))
    call dset(node, "frames", dget(props, "frames"))
    call dset(node, "fps", dget(props, "fps"))
    call dset(node, "duration", dget(props, "duration"))
    call dset(node, "props", props)
    call dset(node, "line", dyn_int(int(lp%no, int64)))
    call dyn_assign(stmt, node)
    has_stmt = .true.
  end subroutine parse_output

  ! ==================================================================
  ! Entry points: Parser.parse_program + parse()
  ! ==================================================================

  subroutine parse_program(p, lines, nlines, program)
    type(parser_state), intent(inout) :: p
    type(line_rec), intent(in) :: lines(:)
    integer, intent(in) :: nlines
    type(dyn), intent(out) :: program
    type(line_rec) :: crec
    type(dyn) :: stmts, stmt, errs, e
    character(:), allocatable :: first
    logical :: has
    integer :: i, j
    stmts = dyn_list()
    i = 1
    do while (i <= nlines)
      crec = lines(i)
      i = i + 1
      if (size(crec%toks) == 0) cycle
      if (allocated(crec%toks(1)%text)) then
        first = word_norm(crec%toks(1)%text)
      else
        first = ""
      end if
      if (first == "group") then
        call parse_group(p, crec, lines, nlines, i, stmt, has)
        if (p%stopped) exit
        if (p%le_set) then
          call parser_error(p, p%le_code, p%le_msg, crec%no, &
                            crec%toks(1)%col)
          call clear_line_error(p)
          if (p%stopped) exit
          cycle
        end if
        if (has) call dyn_list_push(stmts, stmt)
      else if (first == "end") then
        cycle  ! P03 scene...end sugar: block close, ignored
      else
        call parse_statement(p, crec%toks, crec%no, stmt, has)
        if (p%le_set) then
          call parser_error(p, p%le_code, p%le_msg, crec%no, &
                            crec%toks(1)%col)
          call clear_line_error(p)
          if (p%stopped) exit
          cycle
        end if
        if (has) call dyn_list_push(stmts, stmt)
      end if
      if (p%stopped) exit
    end do
    errs = dyn_list()
    if (allocated(p%errs)) then
      do j = 1, size(p%errs)
        e = dyn_list()
        call dyn_list_push(e, dyn_str(p%errs(j)%code))
        call dyn_list_push(e, dyn_str(p%errs(j)%msg))
        call dyn_list_push(e, dyn_int(int(p%errs(j)%line, int64)))
        call dyn_list_push(e, dyn_int(int(p%errs(j)%col, int64)))
        call dyn_list_push(errs, e)
      end do
    end if
    program = dyn_dict()
    call dset(program, "statements", dyn_copy(stmts))
    call dset(program, "span", dyn_null())
    call dset(program, "stmts", dyn_copy(stmts))
    call dset(program, "source", dyn_str(p%source))
    call dset(program, "source_name", dyn_str(p%source))
    call dset(program, "errors", errs)
  end subroutine parse_program

  ! Mirror of parser.parse(text, source_name, bag) -> Program.
  subroutine f3dc_parse(text, source_name, bag, program)
    character(*), intent(in) :: text, source_name
    type(error_bag_t), intent(inout), target :: bag
    type(dyn), intent(out) :: program
    type(parser_state) :: p
    type(line_rec), allocatable :: lines(:)
    integer :: nlines
    p%source = source_name
    p%bag => bag
    allocate(p%errs(0))
    call build_lines(p, text, lines, nlines)
    call parse_program(p, lines, nlines, program)
  end subroutine f3dc_parse

  ! Typed-AST entry point (Phase 6 / C1): the same parse as
  ! f3dc_parse, with the resulting dyn Program node converted to the
  ! typed f3dc_ast representation.  No parse behaviour changes: the
  ! dyn node is built by f3dc_parse itself, diagnostics go to bag and
  ! to the node's "errors" field exactly as there, and the typed
  ! tree can be turned back into that node with ast_program_to_dyn.
  ! ok is set sequentially below (never with .and./.or., which do
  ! not short-circuit): it starts .true. for a dict Program node and
  ! is cleared by a non-empty "errors" list or an error in bag.
  subroutine parse_program_ast(text, source_name, bag, ast, ok)
    character(*), intent(in) :: text, source_name
    type(error_bag_t), intent(inout), target :: bag
    type(ast_program), intent(out) :: ast
    logical, intent(out) :: ok
    type(dyn) :: program, errs
    call f3dc_parse(text, source_name, bag, program)
    ast = ast_program_from_dyn(program)
    ok = .false.
    if (program%kind /= DYN_K_DICT) return
    ok = .true.
    errs = dyn_dict_get(program, "errors")
    if (errs%kind == DYN_K_LIST) then
      if (dyn_list_len(errs) > 0) ok = .false.
    end if
    if (error_bag_has_errors(bag)) ok = .false.
  end subroutine parse_program_ast

end module f3dc_parser
