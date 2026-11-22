! shader.f90 -- custom shaders: RPN evaluator (Wave E, C2).
!
! The compiler (elsewhere) turns a shader expression into a sequence
! of Reverse Polish Notation (RPN) string tokens; this module parses
! those tokens once into integer opcodes + real constants
! (shader_parse) and evaluates the compiled program per sample
! (shader_eval), which is pure and allocation-free.
!
! Tokens:
!   numbers              e.g. "1", "-2.5", "1.0e-3"  (parsed to real(dp))
!   variables            c r g b x y z u v ndl t pi
!                          c   = current channel value (the value the
!                                shader replaces / modulates)
!                          r g b = current colour channels
!                          x y z = position, u v = texture coordinates
!                          ndl = N dot L lighting term, t = time
!                          pi  = the constant 3.14159...
!   binary operators     +  -  *  /  %  ^
!   unary operator       neg          (-a)
!   unary functions      sin cos tan abs sqrt floor ceil fract
!   binary functions     min max step pow
!   ternary functions    clamp mix
!
! Function argument order follows the mathematical notation, i.e.
! operands are pushed in argument order:
!   step(edge, x)   : "edge x step"    -> 1 if x >= edge else 0
!   pow(a, b)       : "a b pow"        (same semantics as "a b ^")
!   clamp(x, a, b)  : "x a b clamp"    -> min(max(x, a), b)
!   mix(a, b, f)    : "a b f mix"      -> a + (b - a) * f
!   fract(x)        : x - floor(x)     (so fract(-1.25) = 0.75)
!
! Semantics guards (shader_eval never raises / never returns NaN for
! these cases):
!   * division by zero            -> 0
!   * modulo by zero              -> 0; otherwise Fortran MOD
!     semantics: mod(a, b) = a - int(a/b)*b, so the result has the
!     sign of the dividend a (mod(-5, 3) = -2, mod(5, -3) = 2).
!   * pow invalid domain          -> 0, i.e. base < 0 with a
!     non-integer exponent, or 0 raised to a negative exponent.
!     The one exception is 0^0 = 1.
!   * sqrt of a negative number   -> 0
!
! Limits: at most 512 tokens per program and a value stack of at
! most 64 entries. shader_parse simulates the stack depth, so a
! program that would underflow (an operator/function with too few
! operands) or overflow (more than 64 values live at once) is
! rejected at parse time with ok = .false. and a message in errmsg,
! as is any unknown token or malformed number.
!
! Empty program: a program parsed from zero tokens is valid and
! shader_eval returns c unchanged (the identity shader).
module shader_3d
    use math_3d, only: dp, PI
    use, intrinsic :: iso_fortran_env, only: int64
    implicit none
    private
    public :: ShaderProg, shader_parse, shader_eval
    public :: SHADER_MAX_TOKENS, SHADER_MAX_STACK

    integer, parameter :: SHADER_MAX_TOKENS = 512
    integer, parameter :: SHADER_MAX_STACK  = 64

    ! Opcodes.
    integer, parameter :: OP_CONST = 1   ! arg = index into consts
    integer, parameter :: OP_VAR   = 2   ! arg = variable id
    integer, parameter :: OP_ADD   = 3
    integer, parameter :: OP_SUB   = 4
    integer, parameter :: OP_MUL   = 5
    integer, parameter :: OP_DIV   = 6
    integer, parameter :: OP_MOD   = 7
    integer, parameter :: OP_POW   = 8
    integer, parameter :: OP_NEG   = 9
    integer, parameter :: OP_SIN   = 10
    integer, parameter :: OP_COS   = 11
    integer, parameter :: OP_TAN   = 12
    integer, parameter :: OP_ABS   = 13
    integer, parameter :: OP_SQRT  = 14
    integer, parameter :: OP_FLOOR = 15
    integer, parameter :: OP_CEIL  = 16
    integer, parameter :: OP_FRACT = 17
    integer, parameter :: OP_MIN   = 18
    integer, parameter :: OP_MAX   = 19
    integer, parameter :: OP_STEP  = 20
    integer, parameter :: OP_CLAMP = 21
    integer, parameter :: OP_MIX   = 22

    ! Variable ids.
    integer, parameter :: VAR_C   = 1
    integer, parameter :: VAR_R   = 2
    integer, parameter :: VAR_G   = 3
    integer, parameter :: VAR_B   = 4
    integer, parameter :: VAR_X   = 5
    integer, parameter :: VAR_Y   = 6
    integer, parameter :: VAR_Z   = 7
    integer, parameter :: VAR_U   = 8
    integer, parameter :: VAR_V   = 9
    integer, parameter :: VAR_NDL = 10
    integer, parameter :: VAR_T   = 11
    integer, parameter :: VAR_PI  = 12

    ! A compiled shader program: parallel arrays of opcodes, opcode
    ! arguments (constant index / variable id, 0 when unused) and the
    ! real constants collected during parsing. Components are private:
    ! build programs only through shader_parse.
    type :: ShaderProg
        private
        integer :: n = 0
        integer :: ops(SHADER_MAX_TOKENS) = 0
        integer :: arg(SHADER_MAX_TOKENS) = 0
        integer :: nconst = 0
        real(dp) :: consts(SHADER_MAX_TOKENS) = 0.0_dp
    end type ShaderProg

contains

    ! Parse RPN tokens into a compiled program.
    ! On failure ok = .false., errmsg describes the problem and prog
    ! is left empty (n = 0, i.e. the identity program).
    subroutine shader_parse(tokens, prog, ok, errmsg)
        character(len=*), intent(in) :: tokens(:)
        type(ShaderProg), intent(out) :: prog
        logical, intent(out) :: ok
        character(len=*), intent(out) :: errmsg

        integer :: i, depth, opcode, arg, arity
        character(len=512) :: tok
        integer :: tlen
        real(dp) :: value
        logical :: is_num

        prog = ShaderProg()
        ok = .true.
        errmsg = ''

        if (size(tokens) > SHADER_MAX_TOKENS) then
            ok = .false.
            errmsg = 'shader_parse: too many tokens (max 512)'
            prog = ShaderProg()
            return
        end if

        depth = 0
        do i = 1, size(tokens)
            if (len_trim(tokens(i)) > len(tok)) then
                ok = .false.
                errmsg = 'shader_parse: token too long'
                prog = ShaderProg()
                return
            end if
            tok = adjustl(tokens(i))
            tlen = len_trim(tok)
            if (tlen == 0) then
                ok = .false.
                errmsg = 'shader_parse: empty token'
                prog = ShaderProg()
                return
            end if

            opcode = 0
            arg = 0
            arity = -1  ! -1: push, 0/1/2: net pops beyond the result

            select case (trim(tok))
            case ('c');   opcode = OP_VAR; arg = VAR_C;   arity = -1
            case ('r');   opcode = OP_VAR; arg = VAR_R;   arity = -1
            case ('g');   opcode = OP_VAR; arg = VAR_G;   arity = -1
            case ('b');   opcode = OP_VAR; arg = VAR_B;   arity = -1
            case ('x');   opcode = OP_VAR; arg = VAR_X;   arity = -1
            case ('y');   opcode = OP_VAR; arg = VAR_Y;   arity = -1
            case ('z');   opcode = OP_VAR; arg = VAR_Z;   arity = -1
            case ('u');   opcode = OP_VAR; arg = VAR_U;   arity = -1
            case ('v');   opcode = OP_VAR; arg = VAR_V;   arity = -1
            case ('ndl'); opcode = OP_VAR; arg = VAR_NDL; arity = -1
            case ('t');   opcode = OP_VAR; arg = VAR_T;   arity = -1
            case ('pi');  opcode = OP_VAR; arg = VAR_PI;  arity = -1
            case ('+');   opcode = OP_ADD;   arity = 1
            case ('-');   opcode = OP_SUB;   arity = 1
            case ('*');   opcode = OP_MUL;   arity = 1
            case ('/');   opcode = OP_DIV;   arity = 1
            case ('%');   opcode = OP_MOD;   arity = 1
            case ('^');   opcode = OP_POW;   arity = 1
            case ('neg');   opcode = OP_NEG;   arity = 0
            case ('sin');   opcode = OP_SIN;   arity = 0
            case ('cos');   opcode = OP_COS;   arity = 0
            case ('tan');   opcode = OP_TAN;   arity = 0
            case ('abs');   opcode = OP_ABS;   arity = 0
            case ('sqrt');  opcode = OP_SQRT;  arity = 0
            case ('floor'); opcode = OP_FLOOR; arity = 0
            case ('ceil');  opcode = OP_CEIL;  arity = 0
            case ('fract'); opcode = OP_FRACT; arity = 0
            case ('min');   opcode = OP_MIN;   arity = 1
            case ('max');   opcode = OP_MAX;   arity = 1
            case ('step');  opcode = OP_STEP;  arity = 1
            case ('pow');   opcode = OP_POW;   arity = 1
            case ('clamp'); opcode = OP_CLAMP; arity = 2
            case ('mix');   opcode = OP_MIX;   arity = 2
            case default
                call parse_number(tok, tlen, value, is_num)
                if (.not. is_num) then
                    ok = .false.
                    errmsg = 'shader_parse: unknown token "' // trim(tok) // '"'
                    prog = ShaderProg()
                    return
                end if
                opcode = OP_CONST
                arity = -1
                prog%nconst = prog%nconst + 1
                prog%consts(prog%nconst) = value
                arg = prog%nconst
            end select

            ! Simulate the value stack.
            if (arity < 0) then
                depth = depth + 1
                if (depth > SHADER_MAX_STACK) then
                    ok = .false.
                    errmsg = 'shader_parse: value stack overflow (max 64)'
                    prog = ShaderProg()
                    return
                end if
            else
                if (depth < arity + 1) then
                    ok = .false.
                    errmsg = 'shader_parse: stack underflow at token "' // &
                             trim(tok) // '"'
                    prog = ShaderProg()
                    return
                end if
                depth = depth - arity
            end if

            prog%n = prog%n + 1
            prog%ops(prog%n) = opcode
            prog%arg(prog%n) = arg
        end do
    end subroutine shader_parse

    ! Evaluate a compiled program. Returns the top of the value
    ! stack; an empty program returns c (identity).
    pure function shader_eval(prog, c, r, g, b, x, y, z, u, v, ndl, t) result(val)
        type(ShaderProg), intent(in) :: prog
        real(dp), intent(in) :: c, r, g, b, x, y, z, u, v, ndl, t
        real(dp) :: val

        real(dp) :: stack(SHADER_MAX_STACK)
        real(dp) :: a, bb, cc
        integer :: sp, i

        if (prog%n <= 0) then
            val = c
            return
        end if

        sp = 0
        do i = 1, prog%n
            select case (prog%ops(i))
            case (OP_CONST)
                sp = sp + 1
                stack(sp) = prog%consts(prog%arg(i))
            case (OP_VAR)
                sp = sp + 1
                select case (prog%arg(i))
                case (VAR_C);   stack(sp) = c
                case (VAR_R);   stack(sp) = r
                case (VAR_G);   stack(sp) = g
                case (VAR_B);   stack(sp) = b
                case (VAR_X);   stack(sp) = x
                case (VAR_Y);   stack(sp) = y
                case (VAR_Z);   stack(sp) = z
                case (VAR_U);   stack(sp) = u
                case (VAR_V);   stack(sp) = v
                case (VAR_NDL); stack(sp) = ndl
                case (VAR_T);   stack(sp) = t
                case default;   stack(sp) = PI  ! VAR_PI
                end select
            case (OP_NEG)
                stack(sp) = -stack(sp)
            case (OP_SIN)
                stack(sp) = sin(stack(sp))
            case (OP_COS)
                stack(sp) = cos(stack(sp))
            case (OP_TAN)
                stack(sp) = tan(stack(sp))
            case (OP_ABS)
                stack(sp) = abs(stack(sp))
            case (OP_SQRT)
                if (stack(sp) < 0.0_dp) then
                    stack(sp) = 0.0_dp
                else
                    stack(sp) = sqrt(stack(sp))
                end if
            case (OP_FLOOR)
                stack(sp) = floor_dp(stack(sp))
            case (OP_CEIL)
                stack(sp) = ceil_dp(stack(sp))
            case (OP_FRACT)
                stack(sp) = stack(sp) - floor_dp(stack(sp))
            case (OP_ADD)
                bb = stack(sp); sp = sp - 1; a = stack(sp)
                stack(sp) = a + bb
            case (OP_SUB)
                bb = stack(sp); sp = sp - 1; a = stack(sp)
                stack(sp) = a - bb
            case (OP_MUL)
                bb = stack(sp); sp = sp - 1; a = stack(sp)
                stack(sp) = a * bb
            case (OP_DIV)
                bb = stack(sp); sp = sp - 1; a = stack(sp)
                if (bb == 0.0_dp) then
                    stack(sp) = 0.0_dp
                else
                    stack(sp) = a / bb
                end if
            case (OP_MOD)
                bb = stack(sp); sp = sp - 1; a = stack(sp)
                if (bb == 0.0_dp) then
                    stack(sp) = 0.0_dp
                else
                    stack(sp) = mod(a, bb)
                end if
            case (OP_POW)
                bb = stack(sp); sp = sp - 1; a = stack(sp)
                stack(sp) = safe_pow(a, bb)
            case (OP_MIN)
                bb = stack(sp); sp = sp - 1; a = stack(sp)
                stack(sp) = min(a, bb)
            case (OP_MAX)
                bb = stack(sp); sp = sp - 1; a = stack(sp)
                stack(sp) = max(a, bb)
            case (OP_STEP)
                ! stack: edge, x -> 1 if x >= edge else 0
                bb = stack(sp); sp = sp - 1; a = stack(sp)
                if (bb >= a) then
                    stack(sp) = 1.0_dp
                else
                    stack(sp) = 0.0_dp
                end if
            case (OP_CLAMP)
                ! stack: x, a, b -> min(max(x, a), b)
                cc = stack(sp); sp = sp - 1
                bb = stack(sp); sp = sp - 1
                a = stack(sp)
                stack(sp) = min(max(a, bb), cc)
            case (OP_MIX)
                ! stack: a, b, f -> a + (b - a) * f
                cc = stack(sp); sp = sp - 1
                bb = stack(sp); sp = sp - 1
                a = stack(sp)
                stack(sp) = a + (bb - a) * cc
            case default
                ! Unreachable for programs built by shader_parse.
                stack(sp) = 0.0_dp
            end select
        end do

        if (sp <= 0) then
            val = c
        else
            val = stack(sp)
        end if
    end function shader_eval

    ! Guarded power: invalid domain -> 0, except 0^0 = 1.
    pure function safe_pow(a, b) result(res)
        real(dp), intent(in) :: a, b
        real(dp) :: res

        if (a == 0.0_dp) then
            if (b < 0.0_dp) then
                res = 0.0_dp
            else if (b == 0.0_dp) then
                res = 1.0_dp
            else
                res = 0.0_dp
            end if
        else if (a < 0.0_dp) then
            if (b == floor_dp(b)) then
                res = a ** b
            else
                res = 0.0_dp
            end if
        else
            res = a ** b
        end if
    end function safe_pow

    ! floor() returning real(dp) (via int64, exact for |x| < 2^63).
    pure function floor_dp(x) result(res)
        real(dp), intent(in) :: x
        real(dp) :: res
        integer(int64) :: n

        if (abs(x) >= 9.0e18_dp) then
            res = x
            return
        end if
        n = int(x, int64)  ! truncation toward zero
        res = real(n, dp)
        if (res > x) res = res - 1.0_dp
    end function floor_dp

    ! ceil() returning real(dp) (via int64, exact for |x| < 2^63).
    pure function ceil_dp(x) result(res)
        real(dp), intent(in) :: x
        real(dp) :: res

        res = -floor_dp(-x)
    end function ceil_dp

    ! Validate and convert a numeric token. Accepts an optional sign,
    ! digits with an optional fractional part, and an optional
    ! decimal exponent (e/E/d/D). Anything else is not a number.
    subroutine parse_number(tok, tlen, value, is_num)
        character(len=*), intent(in) :: tok
        integer, intent(in) :: tlen
        real(dp), intent(out) :: value
        logical, intent(out) :: is_num

        integer :: i, ndig, ios
        logical :: seen_dot, seen_exp
        character(len=512) :: buf

        value = 0.0_dp
        is_num = .false.
        i = 1
        if (i <= tlen .and. (tok(i:i) == '+' .or. tok(i:i) == '-')) i = i + 1
        ndig = 0
        seen_dot = .false.
        do while (i <= tlen)
            if (tok(i:i) >= '0' .and. tok(i:i) <= '9') then
                ndig = ndig + 1
                i = i + 1
            else if (tok(i:i) == '.' .and. .not. seen_dot) then
                seen_dot = .true.
                i = i + 1
            else
                exit
            end if
        end do
        if (ndig == 0) return
        seen_exp = .false.
        if (i <= tlen .and. (tok(i:i) == 'e' .or. tok(i:i) == 'E' .or. &
                             tok(i:i) == 'd' .or. tok(i:i) == 'D')) then
            seen_exp = .true.
            i = i + 1
            if (i <= tlen .and. (tok(i:i) == '+' .or. tok(i:i) == '-')) i = i + 1
            ndig = 0
            do while (i <= tlen .and. tok(i:i) >= '0' .and. tok(i:i) <= '9')
                ndig = ndig + 1
                i = i + 1
            end do
            if (ndig == 0) return
        end if
        if (i <= tlen) return  ! trailing junk

        buf = tok(1:tlen)
        do i = 1, tlen
            if (buf(i:i) == 'd' .or. buf(i:i) == 'D') buf(i:i) = 'e'
        end do
        read(buf, *, iostat=ios) value
        if (ios /= 0) then
            value = 0.0_dp
            return
        end if
        is_num = .true.
    end subroutine parse_number

end module shader_3d
