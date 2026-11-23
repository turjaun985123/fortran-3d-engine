! f3dc_ext_shader.f90 -- custom `shader` statements (Wave E, C2).
!
! Port of tools/f3dc/ext_shader.py (read in full; 567 lines), per
! compiler/DESIGN.md.  Python is the oracle: the expression language
! compiles to RPN that must be IDENTICAL to Python's, because the
! Fortran engine's shader.f90 and the JS runtime both consume it.
!
! Mirror map (ext_shader.py -> this module):
!   EXPR_VARS          -> VAR_NAMES + shader_is_expr_var /
!                         shader_expr_var_count / shader_expr_var_at
!   EXPR_FUNCS         -> FUNC_NAMES/FUNC_ARITY +
!                         shader_expr_func_arity (found=.false. = absent)
!   tokenize_expr      -> shader_tokenize_expr (ok=.false. + err
!                         mirrors the Python ValueError and its text)
!   to_rpn             -> shader_to_rpn (same ValueError contract)
!   validate_shader    -> shader_validate_shader (char_list RPN) and
!                         shader_validate_shader_dyn (dyn RPN, for the
!                         validate-stage wiring; a non-list RPN and
!                         non-string tokens take the Python defensive
!                         branches that dyn can express)
!   scene_lines        -> shader_scene_lines (defs is a dyn list of
!                         dyn dicts {name, rpn|tokens} or dyn 2-lists
!                         [name, rpn], exactly the Python shapes)
!   binding_line       -> shader_binding_line (strings) and
!                         shader_binding_line_dyn (dyn values, Python
!                         str() conversion)
!   (coordinator glue) -> shader_compile: tokenize + to_rpn +
!                         validate_shader in the validate.py order;
!                         ok=.false. means the ValueError path (msgs
!                         holds the single raw ValueError text), while
!                         a compiled shader still returns its
!                         validate_shader messages in msgs.
!
! Error strings are plain human-readable messages (no diagnostic
! codes): validate.py wraps them in E301 diagnostics as
! "shader %r: %s" % (name, msg) -- note validate_shader's own
! messages already begin "shader %r ...", so the wrapped text has
! the prefix twice; that is Python behaviour and is preserved.
!
! No type-bound procedures anywhere (flang build rule).
module f3dc_ext_shader
  use, intrinsic :: iso_fortran_env, only: int64, real64
  use f3dc_str, only: char_list, char_list_append, char_list_len, &
                      char_list_at, char_list_clear, str_box, fmt_int, &
                      fmt_real
  use f3dc_dyn, only: dyn, dyn_null, dyn_bool, dyn_str, dyn_list, &
                      dyn_dict, dyn_dict_get, dyn_dict_has, &
                      dyn_list_push, dyn_list_len, dyn_list_at, &
                      dyn_dict_len, dyn_dict_key_at, &
                      dyn_dict_value_at, DYN_K_NULL, DYN_K_BOOL, &
                      DYN_K_INT, DYN_K_REAL, DYN_K_STR, DYN_K_LIST, &
                      DYN_K_DICT
  implicit none
  private

  public :: shader_tokenize_expr, shader_to_rpn, shader_compile
  public :: shader_validate_shader, shader_validate_shader_dyn
  public :: shader_scene_lines, shader_binding_line, &
            shader_binding_line_dyn
  public :: shader_is_expr_var, shader_expr_var_count, &
            shader_expr_var_at
  public :: shader_expr_func_arity, shader_expr_func_count, &
            shader_expr_func_name_at
  public :: shader_is_number, shader_is_ident

  ! EXPR_VARS (frozen).  Membership only; the sorted rendering used
  ! in messages is SORTED_VARS below.
  character(len=4), parameter :: VAR_NAMES(12) = [character(len=4) :: &
    "c", "r", "g", "b", "x", "y", "z", "u", "v", "ndl", "t", "pi"]
  ! " ".join(sorted(EXPR_VARS)) -- baked in, verified against Python.
  character(len=*), parameter :: SORTED_VARS = &
    "b c g ndl pi r t u v x y z"

  ! EXPR_FUNCS (frozen): name -> arity.
  character(len=8), parameter :: FUNC_NAMES(14) = [character(len=8) :: &
    "sin", "cos", "tan", "abs", "sqrt", "floor", "ceil", "fract", &
    "min", "max", "step", "pow", "clamp", "mix"]
  integer, parameter :: FUNC_ARITY(14) = [ &
    1, 1, 1, 1, 1, 1, 1, 1, 2, 2, 2, 2, 3, 3]

contains

  ! ==================================================================
  ! Character classes (Python str methods, ASCII subset -- Python's
  ! isalpha/isspace/isdigit also match Unicode; shader sources are
  ! ASCII in practice, see the port report)
  ! ==================================================================

  pure logical function is_digit_ch(ch)
    character(len=1), intent(in) :: ch
    is_digit_ch = ch >= "0" .and. ch <= "9"
  end function is_digit_ch

  pure logical function is_alpha_ch(ch)
    character(len=1), intent(in) :: ch
    integer :: c
    c = iachar(ch)
    is_alpha_ch = (c >= iachar("A") .and. c <= iachar("Z")) .or. &
                  (c >= iachar("a") .and. c <= iachar("z"))
  end function is_alpha_ch

  pure logical function is_alnum_ch(ch)
    character(len=1), intent(in) :: ch
    is_alnum_ch = is_alpha_ch(ch) .or. is_digit_ch(ch)
  end function is_alnum_ch

  pure logical function is_space_ch(ch)
    character(len=1), intent(in) :: ch
    integer :: c
    c = iachar(ch)
    is_space_ch = c == 32 .or. (c >= 9 .and. c <= 13)
  end function is_space_ch

  !> Python str.strip() (ASCII whitespace subset).
  function strip_ws(s) result(out)
    character(len=*), intent(in) :: s
    character(len=:), allocatable :: out
    integer :: a, b
    a = 1
    b = len(s)
    do while (a <= b)
      if (.not. is_space_ch(s(a:a))) exit
      a = a + 1
    end do
    do while (b >= a)
      if (.not. is_space_ch(s(b:b))) exit
      b = b - 1
    end do
    if (a > b) then
      out = ""
    else
      out = s(a:b)
    end if
  end function strip_ws

  !> Python repr(str): single quotes unless the string contains a
  !! single quote and no double quote; backslash / quote / control
  !! characters escaped (ASCII subset of CPython's repr, identical
  !! to the repr_str used by f3dc_validate / f3dc_ir).
  function py_repr_str(s) result(out)
    character(len=*), intent(in) :: s
    character(len=:), allocatable :: out, body
    character(len=1) :: quote
    character(len=16), parameter :: HD = "0123456789abcdef"
    integer :: i, c
    if (index(s, "'") > 0 .and. index(s, '"') == 0) then
      quote = '"'
    else
      quote = "'"
    end if
    body = ""
    do i = 1, len(s)
      c = iachar(s(i:i))
      if (s(i:i) == "\" .or. s(i:i) == quote) then
        body = body // "\" // s(i:i)
      else if (c == 10) then
        body = body // "\n"
      else if (c == 13) then
        body = body // "\r"
      else if (c == 9) then
        body = body // "\t"
      else if (c < 32 .or. c == 127) then
        body = body // "\x" // HD(c / 16 + 1:c / 16 + 1) // &
               HD(mod(c, 16) + 1:mod(c, 16) + 1)
      else
        body = body // s(i:i)
      end if
    end do
    out = quote // body // quote
  end function py_repr_str

  !> Python str(dyn) as used by scene_lines / binding_line: strings
  !! as-is, bools True/False, None, numbers via fmt_*, lists in
  !! Python tuple style (dyn conflates tuple/list -- the shaders
  !! payload only ever carries strings, so this is off-path).
  recursive function py_str_dyn(v) result(out)
    type(dyn), intent(in) :: v
    character(len=:), allocatable :: out
    integer :: k
    select case (v%kind)
    case (DYN_K_STR)
      if (allocated(v%s)) then
        out = v%s
      else
        out = ""
      end if
    case (DYN_K_BOOL)
      if (v%b) then
        out = "True"
      else
        out = "False"
      end if
    case (DYN_K_INT)
      out = trim(fmt_int(v%i))
    case (DYN_K_REAL)
      out = trim(fmt_real(v%r))
    case (DYN_K_LIST)
      out = "("
      do k = 1, dyn_list_len(v)
        if (k > 1) out = out // ", "
        out = out // py_repr_dyn(dyn_list_at(v, k))
      end do
      if (dyn_list_len(v) == 1) out = out // ","
      out = out // ")"
    case (DYN_K_DICT)
      out = "{"
      do k = 1, dyn_dict_len(v)
        if (k > 1) out = out // ", "
        out = out // py_repr_str(dyn_dict_key_at(v, k)) // ": " // &
              py_repr_dyn(dyn_dict_value_at(v, k))
      end do
      out = out // "}"
    case default
      out = "None"
    end select
  end function py_str_dyn

  !> Python repr(dyn) for the validate_shader non-token message.
  recursive function py_repr_dyn(v) result(out)
    type(dyn), intent(in) :: v
    character(len=:), allocatable :: out
    if (v%kind == DYN_K_STR) then
      if (allocated(v%s)) then
        out = py_repr_str(v%s)
      else
        out = "''"
      end if
    else
      out = py_str_dyn(v)
    end if
  end function py_repr_dyn

  ! ==================================================================
  ! Frozen vocabulary
  ! ==================================================================

  pure logical function shader_is_expr_var(tok)
    character(len=*), intent(in) :: tok
    integer :: k
    shader_is_expr_var = .false.
    do k = 1, size(VAR_NAMES)
      if (tok == trim(VAR_NAMES(k))) shader_is_expr_var = .true.
    end do
  end function shader_is_expr_var

  pure integer function shader_expr_var_count()
    shader_expr_var_count = size(VAR_NAMES)
  end function shader_expr_var_count

  function shader_expr_var_at(idx) result(out)
    integer, intent(in) :: idx
    character(len=:), allocatable :: out
    if (idx < 1 .or. idx > size(VAR_NAMES)) then
      out = ""
    else
      out = trim(VAR_NAMES(idx))
    end if
  end function shader_expr_var_at

  !> EXPR_FUNCS lookup: found=.false. when tok is not a function.
  subroutine shader_expr_func_arity(tok, arity, found)
    character(len=*), intent(in) :: tok
    integer, intent(out) :: arity
    logical, intent(out) :: found
    integer :: k
    arity = 0
    found = .false.
    do k = 1, size(FUNC_NAMES)
      if (tok == trim(FUNC_NAMES(k))) then
        arity = FUNC_ARITY(k)
        found = .true.
        return
      end if
    end do
  end subroutine shader_expr_func_arity

  pure integer function shader_expr_func_count()
    shader_expr_func_count = size(FUNC_NAMES)
  end function shader_expr_func_count

  function shader_expr_func_name_at(idx) result(out)
    integer, intent(in) :: idx
    character(len=:), allocatable :: out
    if (idx < 1 .or. idx > size(FUNC_NAMES)) then
      out = ""
    else
      out = trim(FUNC_NAMES(idx))
    end if
  end function shader_expr_func_name_at

  pure logical function is_func(tok)
    character(len=*), intent(in) :: tok
    integer :: k
    is_func = .false.
    do k = 1, size(FUNC_NAMES)
      if (tok == trim(FUNC_NAMES(k))) is_func = .true.
    end do
  end function is_func

  pure logical function is_binary_op(tok)
    character(len=*), intent(in) :: tok
    is_binary_op = len(tok) == 1 .and. index("+-*/%^", tok) > 0
  end function is_binary_op

  !> _PRECEDENCE (binary ops + "neg"); 0 when not an operator.
  pure integer function precedence(tok)
    character(len=*), intent(in) :: tok
    if (tok == "+" .or. tok == "-") then
      precedence = 1
    else if (tok == "*" .or. tok == "/" .or. tok == "%") then
      precedence = 2
    else if (tok == "neg") then
      precedence = 3
    else if (tok == "^") then
      precedence = 4
    else
      precedence = 0
    end if
  end function precedence

  pure logical function is_right_assoc(tok)
    character(len=*), intent(in) :: tok
    is_right_assoc = tok == "^" .or. tok == "neg"
  end function is_right_assoc

  !> _NUMBER_RE.fullmatch: (?:\d+(?:\.\d*)?|\.\d+)
  pure logical function shader_is_number(tok)
    character(len=*), intent(in) :: tok
    integer :: i, ndig
    shader_is_number = .false.
    if (len(tok) == 0) return
    i = 1
    if (tok(1:1) == ".") then
      ! \.\d+ : a dot then at least one digit, nothing else.
      if (len(tok) < 2) return
      do i = 2, len(tok)
        if (.not. is_digit_ch(tok(i:i))) return
      end do
      shader_is_number = .true.
      return
    end if
    ndig = 0
    do while (i <= len(tok))
      if (.not. is_digit_ch(tok(i:i))) exit
      ndig = ndig + 1
      i = i + 1
    end do
    if (ndig == 0) return
    if (i <= len(tok)) then
      if (tok(i:i) /= ".") return
      i = i + 1
      do while (i <= len(tok))
        if (.not. is_digit_ch(tok(i:i))) return
        i = i + 1
      end do
    end if
    shader_is_number = .true.
  end function shader_is_number

  !> _IDENT_RE.fullmatch: [A-Za-z_][A-Za-z0-9_]*
  pure logical function shader_is_ident(tok)
    character(len=*), intent(in) :: tok
    integer :: i
    shader_is_ident = .false.
    if (len(tok) == 0) return
    if (.not. (is_alpha_ch(tok(1:1)) .or. tok(1:1) == "_")) return
    do i = 2, len(tok)
      if (.not. (is_alnum_ch(tok(i:i)) .or. tok(i:i) == "_")) return
    end do
    shader_is_ident = .true.
  end function shader_is_ident

  ! ==================================================================
  ! tokenize_expr
  ! ==================================================================

  !> Split an expression source string into tokens.  Numbers are
  !! kept verbatim, identifiers as written, every operator /
  !! parenthesis / comma is its own single-character token.
  !! ok=.false. + err mirrors the Python ValueError (non-string
  !! input cannot occur through this typed API).
  subroutine shader_tokenize_expr(src, tokens, err, ok)
    character(len=*), intent(in) :: src
    type(char_list), intent(inout) :: tokens
    character(len=:), allocatable, intent(out) :: err
    logical, intent(out) :: ok
    integer :: i, j, n
    character(len=1) :: ch
    character(len=:), allocatable :: text
    logical :: is_num_start
    call char_list_clear(tokens)
    err = ""
    ok = .true.
    n = len(src)
    i = 1
    do while (i <= n)
      ch = src(i:i)
      if (is_space_ch(ch)) then
        i = i + 1
        cycle
      end if
      is_num_start = is_digit_ch(ch)
      if (.not. is_num_start .and. ch == ".") then
        if (i + 1 <= n) is_num_start = is_digit_ch(src(i + 1:i + 1))
      end if
      if (is_num_start) then
        j = i
        do while (j <= n)
          if (.not. (is_digit_ch(src(j:j)) .or. src(j:j) == ".")) exit
          j = j + 1
        end do
        text = src(i:j - 1)
        if (.not. shader_is_number(text)) then
          err = "malformed number " // py_repr_str(text) // &
                " in shader expression"
          ok = .false.
          return
        end if
        call char_list_append(tokens, text)
        i = j
        cycle
      end if
      if (is_alpha_ch(ch) .or. ch == "_") then
        j = i
        do while (j <= n)
          if (.not. (is_alnum_ch(src(j:j)) .or. src(j:j) == "_")) exit
          j = j + 1
        end do
        call char_list_append(tokens, src(i:j - 1))
        i = j
        cycle
      end if
      if (index("+-*/%^(),", ch) > 0) then
        call char_list_append(tokens, ch)
        i = i + 1
        cycle
      end if
      err = "invalid character " // py_repr_str(ch) // &
            " in shader expression"
      ok = .false.
      return
    end do
  end subroutine shader_tokenize_expr

  ! ==================================================================
  ! to_rpn: shunting-yard, infix tokens -> RPN
  ! ==================================================================

  !> Compile infix tokens (from shader_tokenize_expr) to RPN.
  !! Numbers and variables pass through as-is, binary operators are
  !! emitted as their single character, unary minus as "neg", and a
  !! function name is emitted after its arguments.  ok=.false. +
  !! err mirrors every Python ValueError message, byte for byte.
  subroutine shader_to_rpn(tokens, rpn, err, ok)
    type(char_list), intent(in) :: tokens
    type(char_list), intent(inout) :: rpn
    character(len=:), allocatable, intent(out) :: err
    logical, intent(out) :: ok
    integer :: ntok, i, k
    ! Operator stack (entries: "(", a function name, a binary op,
    ! or "neg") and the parallel _Paren frames.
    type(str_box), allocatable :: ops(:), pfunc(:)
    integer, allocatable :: pcommas(:)
    logical, allocatable :: phas(:)
    integer :: nops, npar
    logical :: expect_operand
    character(len=:), allocatable :: token, top, fn
    integer :: arity, argc, prec, top_prec
    logical :: found

    call char_list_clear(rpn)
    err = ""
    ok = .true.
    ntok = char_list_len(tokens)
    if (ntok == 0) then
      err = "empty shader expression: nothing to compile"
      ok = .false.
      return
    end if
    allocate (ops(ntok + 2), pfunc(ntok + 2), pcommas(ntok + 2), &
              phas(ntok + 2))
    nops = 0
    npar = 0
    expect_operand = .true.

    i = 1
    do while (i <= ntok)
      token = char_list_at(tokens, i)
      if (expect_operand) then
        if (shader_is_number(token)) then
          call char_list_append(rpn, token)
          if (npar > 0) phas(npar) = .true.
          expect_operand = .false.
        else if (is_func(token)) then
          if (i + 1 > ntok) then
            err = "function " // py_repr_str(token) // &
                  " must be followed by '(' in shader expression"
            ok = .false.
          else if (char_list_at(tokens, i + 1) /= "(") then
            err = "function " // py_repr_str(token) // &
                  " must be followed by '(' in shader expression"
            ok = .false.
          else
            nops = nops + 1
            ops(nops)%s = token
            ! The "(" on the next iteration opens its frame.
          end if
        else if (shader_is_ident(token)) then
          if (i + 1 <= ntok .and. &
              char_list_at(tokens, i + 1) == "(") then
            if (shader_is_expr_var(token)) then
              err = "missing operator before '(' in shader expression"
              ok = .false.
            else
              err = "unknown function " // py_repr_str(token) // &
                    " in shader expression"
              ok = .false.
            end if
          else if (.not. shader_is_expr_var(token)) then
            err = "unknown variable " // py_repr_str(token) // &
                  " in shader expression: variables are " // &
                  SORTED_VARS
            ok = .false.
          else
            call char_list_append(rpn, token)
            if (npar > 0) phas(npar) = .true.
            expect_operand = .false.
          end if
        else if (token == "-") then
          ! Unary minus: pushed without popping, so it binds to the
          ! operand that follows (2 ^ -3, -x).
          nops = nops + 1
          ops(nops)%s = "neg"
        else if (token == "(") then
          fn = ""
          if (nops > 0) then
            if (is_func(ops(nops)%s)) fn = ops(nops)%s
          end if
          nops = nops + 1
          ops(nops)%s = "("
          npar = npar + 1
          pfunc(npar)%s = fn
          pcommas(npar) = 0
          phas(npar) = .false.
        else if (token == ")") then
          if (npar == 0) then
            err = "unbalanced parentheses in shader expression: " // &
                  "unexpected ')'"
            ok = .false.
          else if (len(pfunc(npar)%s) > 0 .and. &
                   .not. phas(npar) .and. pcommas(npar) == 0) then
            call shader_expr_func_arity(pfunc(npar)%s, arity, found)
            err = "function " // py_repr_str(pfunc(npar)%s) // &
                  " called with 0 arguments in shader expression: " &
                  // py_repr_str(pfunc(npar)%s) // " expects " // &
                  trim(fmt_int(int(arity, int64))) // " argument(s)"
            ok = .false.
          else
            err = "missing operand before ')' in shader expression"
            ok = .false.
          end if
        else if (token == ",") then
          err = "missing operand before ',' in shader expression"
          ok = .false.
        else if (is_binary_op(token)) then
          err = "missing operand before operator " // &
                py_repr_str(token) // " in shader expression"
          ok = .false.
        else if (len(token) > 0 .and. &
                 (is_digit_ch(token(1:1)) .or. token(1:1) == ".")) then
          err = "malformed number " // py_repr_str(token) // &
                " in shader expression"
          ok = .false.
        else
          err = "unknown token " // py_repr_str(token) // &
                " in shader expression"
          ok = .false.
        end if
      else
        if (is_binary_op(token)) then
          ! push_binary(token)
          prec = precedence(token)
          do while (nops > 0)
            top = ops(nops)%s
            if (top == "(" .or. is_func(top)) exit
            top_prec = precedence(top)
            if (top_prec > prec .or. (top_prec == prec .and. &
                .not. is_right_assoc(token))) then
              call char_list_append(rpn, top)
              nops = nops - 1
            else
              exit
            end if
          end do
          nops = nops + 1
          ops(nops)%s = token
          expect_operand = .true.
        else if (token == ",") then
          if (npar == 0) then
            err = "unbalanced parentheses in shader expression: " // &
                  "',' outside any parentheses"
            ok = .false.
          else
            do while (nops > 0)
              if (ops(nops)%s == "(") exit
              call char_list_append(rpn, ops(nops)%s)
              nops = nops - 1
            end do
            if (nops == 0) then
              err = "unbalanced parentheses in shader expression: " &
                    // "',' without a matching '('"
              ok = .false.
            else if (len(pfunc(npar)%s) == 0) then
              err = "',' is only allowed inside a function call " // &
                    "in shader expression"
              ok = .false.
            else if (.not. phas(npar)) then
              err = "missing argument before ',' in call to " // &
                    "function " // py_repr_str(pfunc(npar)%s) // &
                    " in shader expression"
              ok = .false.
            else
              pcommas(npar) = pcommas(npar) + 1
              phas(npar) = .false.
              expect_operand = .true.
            end if
          end if
        else if (token == ")") then
          if (npar == 0) then
            err = "unbalanced parentheses in shader expression: " // &
                  "unexpected ')'"
            ok = .false.
          else
            do while (nops > 0)
              if (ops(nops)%s == "(") exit
              call char_list_append(rpn, ops(nops)%s)
              nops = nops - 1
            end do
            if (nops == 0) then
              ! pragma: no cover in Python -- parens guards this.
              err = "unbalanced parentheses in shader expression: " &
                    // "unexpected ')'"
              ok = .false.
            else
              nops = nops - 1  ! discard the "("
              fn = pfunc(npar)%s
              argc = pcommas(npar)
              if (phas(npar)) argc = argc + 1
              npar = npar - 1
              if (len(fn) > 0) then
                if (nops > 0) then
                  if (ops(nops)%s == fn) nops = nops - 1
                end if
                call shader_expr_func_arity(fn, arity, found)
                if (argc /= arity) then
                  err = "function " // py_repr_str(fn) // &
                        " called with " // &
                        trim(fmt_int(int(argc, int64))) // &
                        " argument(s) in shader expression: " // &
                        py_repr_str(fn) // " expects " // &
                        trim(fmt_int(int(arity, int64))) // &
                        " argument(s)"
                  ok = .false.
                else
                  call char_list_append(rpn, fn)
                end if
              else if (argc == 0) then
                ! not has_arg and commas == 0
                err = "empty parentheses in shader expression"
                ok = .false.
              end if
              if (ok) then
                if (npar > 0) phas(npar) = .true.
                expect_operand = .false.
              end if
            end if
          end if
        else if (token == "(") then
          err = "missing operator before '(' in shader expression"
          ok = .false.
        else if (shader_is_number(token) .or. &
                 shader_is_ident(token) .or. is_func(token)) then
          err = "missing operator before " // py_repr_str(token) // &
                " in shader expression"
          ok = .false.
        else
          err = "unknown token " // py_repr_str(token) // &
                " in shader expression"
          ok = .false.
        end if
      end if
      if (.not. ok) return
      i = i + 1
    end do

    if (npar > 0) then
      err = "unbalanced parentheses in shader expression: missing ')'"
      ok = .false.
      return
    end if
    do k = 1, nops
      if (ops(k)%s == "(") then
        err = "unbalanced parentheses in shader expression: " // &
              "missing ')'"
        ok = .false.
        return
      end if
    end do
    if (expect_operand) then
      token = char_list_at(tokens, ntok)
      if (is_binary_op(token)) then
        err = "trailing operator " // py_repr_str(token) // &
              " in shader expression: the expression ends before " // &
              "its right-hand operand"
      else if (is_func(token)) then
        err = "function " // py_repr_str(token) // &
              " in shader expression has no argument list"
      else
        err = "incomplete shader expression: an operand is " // &
              "missing at the end"
      end if
      ok = .false.
      return
    end if
    do while (nops > 0)
      top = ops(nops)%s
      nops = nops - 1
      if (top == "(") then
        ! pragma: no cover in Python -- checked above.
        err = "unbalanced parentheses in shader expression: " // &
              "missing ')'"
        ok = .false.
        call char_list_clear(rpn)
        return
      end if
      call char_list_append(rpn, top)
    end do
    if (char_list_len(rpn) == 0) then
      ! pragma: no cover in Python -- empty input checked above.
      err = "empty shader expression: nothing to compile"
      ok = .false.
    end if
  end subroutine shader_to_rpn

  ! ==================================================================
  ! validate_shader
  ! ==================================================================

  !> The name half of validate_shader: appends the name errors and
  !! returns the label the remaining messages use.
  subroutine validate_name(name, errors, label)
    character(len=*), intent(in) :: name
    type(char_list), intent(inout) :: errors
    character(len=:), allocatable, intent(out) :: label
    character(len=:), allocatable :: stripped
    stripped = strip_ws(name)
    if (len(stripped) == 0) then
      call char_list_append(errors, &
        "shader has no name: 'shader' must name the shader " // &
        "before its expression")
      label = "<unnamed>"
    else
      label = name
      if (.not. shader_is_ident(stripped)) then
        call char_list_append(errors, &
          "shader name " // py_repr_str(name) // &
          " is not a valid identifier: a shader name must start " // &
          "with a letter or '_' and contain only letters, digits " // &
          "and '_'")
      end if
    end if
  end subroutine validate_name

  !> Shared stack simulation.  toks holds the token text; is_str(k)
  !! is .false. for a non-string token, whose Python repr is in
  !! reprs(k) (the char_list entry point passes all-.true.).
  subroutine validate_stack(label, toks, is_str, reprs, errors)
    character(len=*), intent(in) :: label
    type(char_list), intent(in) :: toks, reprs
    logical, intent(in) :: is_str(:)
    type(char_list), intent(inout) :: errors
    character(len=:), allocatable :: token, lab
    integer :: depth, k, arity
    logical :: found
    lab = py_repr_str(label)
    depth = 0
    do k = 1, char_list_len(toks)
      if (.not. is_str(k)) then
        call char_list_append(errors, &
          "shader " // lab // " expression contains a non-token " // &
          "value " // char_list_at(reprs, k))
        cycle
      end if
      token = char_list_at(toks, k)
      if (shader_is_number(token)) then
        depth = depth + 1
      else if (shader_is_expr_var(token)) then
        depth = depth + 1
      else if (token == "neg") then
        if (depth < 1) &
          call char_list_append(errors, &
            "shader " // lab // " expression applies unary minus " &
            // "with no operand")
        ! neg consumes one value and produces one: depth fixed.
      else if (is_binary_op(token)) then
        if (depth < 2) then
          call char_list_append(errors, &
            "shader " // lab // " expression applies operator " // &
            py_repr_str(token) // " with fewer than two operands")
          depth = 1
        else
          depth = depth - 1
        end if
      else if (is_func(token)) then
        call shader_expr_func_arity(token, arity, found)
        if (depth < arity) then
          call char_list_append(errors, &
            "shader " // lab // " expression calls function " // &
            py_repr_str(token) // " with fewer than its " // &
            trim(fmt_int(int(arity, int64))) // " argument(s)")
          depth = 1
        else
          depth = depth - arity + 1
        end if
      else if (shader_is_ident(token)) then
        call char_list_append(errors, &
          "shader " // lab // " expression contains unknown " // &
          "variable " // py_repr_str(token) // ": variables are " // &
          SORTED_VARS)
        ! Count it as a value so one bad name yields one error.
        depth = depth + 1
      else
        call char_list_append(errors, &
          "shader " // lab // " expression contains unknown token " &
          // py_repr_str(token))
      end if
    end do
    if (depth /= 1) &
      call char_list_append(errors, &
        "shader " // lab // " expression leaves " // &
        trim(fmt_int(int(depth, int64))) // &
        " values instead of one: operands or operators are missing")
  end subroutine validate_stack

  !> validate_shader(name, rpn): human-readable errors for one
  !! shader definition; an empty errors list means valid.
  subroutine shader_validate_shader(name, rpn, errors)
    character(len=*), intent(in) :: name
    type(char_list), intent(in) :: rpn
    type(char_list), intent(inout) :: errors
    character(len=:), allocatable :: label
    logical, allocatable :: is_str(:)
    type(char_list) :: reprs
    integer :: k
    call char_list_clear(errors)
    call validate_name(name, errors, label)
    if (char_list_len(rpn) == 0) then
      call char_list_append(errors, &
        "shader " // py_repr_str(label) // &
        " has an empty expression: 'expr' must contain at least " // &
        "one token")
      return
    end if
    allocate (is_str(char_list_len(rpn)))
    is_str = .true.
    do k = 1, char_list_len(rpn)
      call char_list_append(reprs, "")
    end do
    call validate_stack(label, rpn, is_str, reprs, errors)
  end subroutine shader_validate_shader

  !> validate_shader over a dyn RPN: a non-list RPN takes the
  !! Python "no compiled expression" branch, and non-string list
  !! items take the "non-token value %r" branch.
  subroutine shader_validate_shader_dyn(name, rpn, errors)
    character(len=*), intent(in) :: name
    type(dyn), intent(in) :: rpn
    type(char_list), intent(inout) :: errors
    character(len=:), allocatable :: label
    type(char_list) :: toks, reprs
    logical, allocatable :: is_str(:)
    type(dyn) :: item
    integer :: k, n
    call char_list_clear(errors)
    call validate_name(name, errors, label)
    if (rpn%kind /= DYN_K_LIST) then
      call char_list_append(errors, &
        "shader " // py_repr_str(label) // &
        " has no compiled expression: its 'expr' must compile to " // &
        "a non-empty token list")
      return
    end if
    n = dyn_list_len(rpn)
    if (n == 0) then
      call char_list_append(errors, &
        "shader " // py_repr_str(label) // &
        " has an empty expression: 'expr' must contain at least " // &
        "one token")
      return
    end if
    allocate (is_str(n))
    do k = 1, n
      item = dyn_list_at(rpn, k)
      if (item%kind == DYN_K_STR .and. allocated(item%s)) then
        is_str(k) = .true.
        call char_list_append(toks, item%s)
        call char_list_append(reprs, "")
      else
        is_str(k) = .false.
        call char_list_append(toks, "")
        call char_list_append(reprs, py_repr_dyn(item))
      end if
    end do
    call validate_stack(label, toks, is_str, reprs, errors)
  end subroutine shader_validate_shader_dyn

  ! ==================================================================
  ! Coordinator glue (validate.py's try/except around this module)
  ! ==================================================================

  !> tokenize_expr + to_rpn + validate_shader, in validate.py's
  !! order.  ok=.false. mirrors the ValueError path: msgs then
  !! holds the single raw ValueError text and rpn is an empty dyn
  !! list.  On success rpn is the dyn list of dyn_str RPN tokens
  !! (the IR payload validate.py stores) and msgs holds the
  !! validate_shader messages (possibly none).
  subroutine shader_compile(name, expr, rpn, msgs, ok)
    character(len=*), intent(in) :: name, expr
    type(dyn), intent(out) :: rpn
    type(char_list), intent(inout) :: msgs
    logical, intent(out) :: ok
    type(char_list) :: tokens, rpn_list
    character(len=:), allocatable :: err
    integer :: k
    call char_list_clear(msgs)
    rpn = dyn_list()
    call shader_tokenize_expr(expr, tokens, err, ok)
    if (.not. ok) then
      call char_list_append(msgs, err)
      return
    end if
    call shader_to_rpn(tokens, rpn_list, err, ok)
    if (.not. ok) then
      call char_list_append(msgs, err)
      return
    end if
    do k = 1, char_list_len(rpn_list)
      call dyn_list_push(rpn, dyn_str(char_list_at(rpn_list, k)))
    end do
    call shader_validate_shader(name, rpn_list, msgs)
  end subroutine shader_compile

  ! ==================================================================
  ! Emit lines
  ! ==================================================================

  !> Tokens of one definition's RPN payload as strings: a dyn list
  !! of values (str() of each), a dyn string (Python iterates its
  !! characters), a dyn dict (Python iterates its keys); anything
  !! else (or null) yields no tokens -- Python would raise inside
  !! scene_lines for a non-iterable, which the emit call site's
  !! try/except swallows; see the port report.
  subroutine rpn_tokens_of(rpn, toks)
    type(dyn), intent(in) :: rpn
    type(char_list), intent(inout) :: toks
    integer :: k
    call char_list_clear(toks)
    select case (rpn%kind)
    case (DYN_K_LIST)
      do k = 1, dyn_list_len(rpn)
        call char_list_append(toks, &
                              py_str_dyn(dyn_list_at(rpn, k)))
      end do
    case (DYN_K_STR)
      if (allocated(rpn%s)) then
        do k = 1, len(rpn%s)
          call char_list_append(toks, rpn%s(k:k))
        end do
      end if
    case (DYN_K_DICT)
      do k = 1, dyn_dict_len(rpn)
        call char_list_append(toks, dyn_dict_key_at(rpn, k))
      end do
    end select
  end subroutine rpn_tokens_of

  !> scene_lines(defs): one "shaderdef NAME NTOK tok1 ... tokN"
  !! line per definition, in order.  defs is a dyn list whose items
  !! are dyn dicts {name, rpn|tokens} or dyn 2-lists [name, rpn]
  !! (the Python tuple/list shape); any other item is skipped, as
  !! in Python's defensive branch.  A non-list / empty defs gives
  !! no lines.
  subroutine shader_scene_lines(defs, lines)
    type(dyn), intent(in) :: defs
    type(char_list), intent(inout) :: lines
    type(dyn) :: item, name_v, rpn_v
    type(char_list) :: toks
    character(len=:), allocatable :: name, joined
    integer :: k, j
    call char_list_clear(lines)
    if (defs%kind /= DYN_K_LIST) return
    do k = 1, dyn_list_len(defs)
      item = dyn_list_at(defs, k)
      if (item%kind == DYN_K_DICT) then
        if (dyn_dict_has(item, "name")) then
          name_v = dyn_dict_get(item, "name")
        else
          name_v = dyn_str("")
        end if
        if (dyn_dict_has(item, "rpn")) then
          rpn_v = dyn_dict_get(item, "rpn")
        else if (dyn_dict_has(item, "tokens")) then
          rpn_v = dyn_dict_get(item, "tokens")
        else
          rpn_v = dyn_list()
        end if
      else if (item%kind == DYN_K_LIST .and. &
               dyn_list_len(item) == 2) then
        name_v = dyn_list_at(item, 1)
        rpn_v = dyn_list_at(item, 2)
      else
        cycle  ! defensive, off-contract input (Python: continue)
      end if
      name = strip_ws(py_str_dyn(name_v))
      call rpn_tokens_of(rpn_v, toks)
      if (char_list_len(toks) > 0) then
        joined = char_list_at(toks, 1)
        do j = 2, char_list_len(toks)
          joined = joined // " " // char_list_at(toks, j)
        end do
        call char_list_append(lines, &
          "shaderdef " // name // " " // &
          trim(fmt_int(int(char_list_len(toks), int64))) // " " // &
          joined)
      else
        call char_list_append(lines, "shaderdef " // name // " 0")
      end if
    end do
  end subroutine shader_scene_lines

  !> binding_line(obj, shader_name): "shaderbind OBJ SHADER", both
  !! sides stripped (Python str(...).strip()).
  function shader_binding_line(obj, shader_name) result(out)
    character(len=*), intent(in) :: obj, shader_name
    character(len=:), allocatable :: out
    out = "shaderbind " // strip_ws(obj) // " " // &
          strip_ws(shader_name)
  end function shader_binding_line

  !> binding_line over dyn values (Python str() conversion first).
  function shader_binding_line_dyn(obj, shader_name) result(out)
    type(dyn), intent(in) :: obj, shader_name
    character(len=:), allocatable :: out
    out = shader_binding_line(py_str_dyn(obj), &
                              py_str_dyn(shader_name))
  end function shader_binding_line_dyn

end module f3dc_ext_shader
