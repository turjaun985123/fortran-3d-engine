program test_shader
    use math_3d, only: dp, PI
    use shader_3d
    use test_assert
    implicit none

    type(ShaderProg) :: prog
    logical :: ok
    character(len=256) :: errmsg
    character(len=4) :: empty_tokens(0)
    character(len=2) :: many_tokens(65)
    integer :: i
    real(dp), parameter :: tol = 1.0e-12_dp

    ! ---- empty program: identity (returns c) ----
    call shader_parse(empty_tokens, prog, ok, errmsg)
    call assert_true(ok, 'empty token list parses ok')
    call assert_real_close(0.33_dp, shader_eval(prog, 0.33_dp, 0.0_dp, 0.0_dp, &
        0.0_dp, 0.0_dp, 0.0_dp, 0.0_dp, 0.0_dp, 0.0_dp, 0.0_dp, 0.0_dp), tol, &
        'empty program evaluates to c (identity)')

    ! ---- identity / constants ----
    call assert_real_close(0.42_dp, run([character(len=1) :: 'c'], &
        0.42_dp, 0.0_dp, 0.0_dp, 0.0_dp), tol, 'identity expr "c" returns c')
    call assert_real_close(3.5_dp, run([character(len=3) :: '3.5'], &
        0.42_dp, 0.0_dp, 0.0_dp, 0.0_dp), tol, 'constant expr "3.5" returns 3.5')
    call assert_real_close(100.0_dp, run([character(len=3) :: '1e2'], &
        0.0_dp, 0.0_dp, 0.0_dp, 0.0_dp), tol, 'constant expr "1e2" returns 100')
    call assert_real_close(PI, run([character(len=2) :: 'pi'], &
        0.0_dp, 0.0_dp, 0.0_dp, 0.0_dp), tol, 'variable pi returns PI')

    ! ---- variables r,g,b and z,u,v,t ----
    call shader_parse([character(len=1) :: 'r', 'g', 'b', '+', '+'], prog, ok, errmsg)
    call assert_true(ok, 'r g b + + parses ok')
    call assert_real_close(6.0_dp, shader_eval(prog, 0.0_dp, 1.0_dp, 2.0_dp, &
        3.0_dp, 0.0_dp, 0.0_dp, 0.0_dp, 0.0_dp, 0.0_dp, 0.0_dp, 0.0_dp), tol, &
        'r+g+b at (1,2,3) is 6')
    call shader_parse([character(len=1) :: 'z', 'u', 'v', 't', '+', '+', '+'], &
        prog, ok, errmsg)
    call assert_true(ok, 'z u v t + + + parses ok')
    call assert_real_close(10.0_dp, shader_eval(prog, 0.0_dp, 0.0_dp, 0.0_dp, &
        0.0_dp, 0.0_dp, 0.0_dp, 1.0_dp, 2.0_dp, 3.0_dp, 0.0_dp, 4.0_dp), tol, &
        'z+u+v+t at (1,2,3,4) is 10')

    ! ---- arithmetic (precedence already encoded in the RPN) ----
    ! 1 + 2*3 = 7
    call assert_real_close(7.0_dp, run([character(len=1) :: &
        '1', '2', '3', '*', '+'], 0.0_dp, 0.0_dp, 0.0_dp, 0.0_dp), tol, &
        'RPN 1 2 3 * + is 7 (1+2*3)')
    ! (2+3)*4 = 20
    call assert_real_close(20.0_dp, run([character(len=1) :: &
        '2', '3', '+', '4', '*'], 0.0_dp, 0.0_dp, 0.0_dp, 0.0_dp), tol, &
        'RPN 2 3 + 4 * is 20 ((2+3)*4)')
    call assert_real_close(6.0_dp, run([character(len=2) :: '10', '4', '-'], &
        0.0_dp, 0.0_dp, 0.0_dp, 0.0_dp), tol, '10-4 is 6')
    call assert_real_close(3.5_dp, run([character(len=1) :: '7', '2', '/'], &
        0.0_dp, 0.0_dp, 0.0_dp, 0.0_dp), tol, '7/2 is 3.5')
    call assert_real_close(-5.0_dp, run([character(len=3) :: '5', 'neg'], &
        0.0_dp, 0.0_dp, 0.0_dp, 0.0_dp), tol, 'neg(5) is -5')

    ! ---- unary functions at known values ----
    call assert_real_close(0.0_dp, run([character(len=3) :: '0', 'sin'], &
        0.0_dp, 0.0_dp, 0.0_dp, 0.0_dp), tol, 'sin(0) is 0')
    call assert_real_close(1.0_dp, run([character(len=3) :: &
        'pi', '2', '/', 'sin'], 0.0_dp, 0.0_dp, 0.0_dp, 0.0_dp), 1.0e-9_dp, &
        'sin(pi/2) is 1')
    call assert_real_close(1.0_dp, run([character(len=3) :: '0', 'cos'], &
        0.0_dp, 0.0_dp, 0.0_dp, 0.0_dp), tol, 'cos(0) is 1')
    call assert_real_close(0.0_dp, run([character(len=3) :: '0', 'tan'], &
        0.0_dp, 0.0_dp, 0.0_dp, 0.0_dp), tol, 'tan(0) is 0')
    call assert_real_close(3.0_dp, run([character(len=3) :: '-3', 'abs'], &
        0.0_dp, 0.0_dp, 0.0_dp, 0.0_dp), tol, 'abs(-3) is 3')
    call assert_real_close(3.0_dp, run([character(len=4) :: '9', 'sqrt'], &
        0.0_dp, 0.0_dp, 0.0_dp, 0.0_dp), tol, 'sqrt(9) is 3')
    call assert_real_close(0.0_dp, run([character(len=4) :: '-4', 'sqrt'], &
        0.0_dp, 0.0_dp, 0.0_dp, 0.0_dp), tol, 'sqrt(-4) is guarded to 0')
    call assert_real_close(2.0_dp, run([character(len=5) :: '2.7', 'floor'], &
        0.0_dp, 0.0_dp, 0.0_dp, 0.0_dp), tol, 'floor(2.7) is 2')
    call assert_real_close(-3.0_dp, run([character(len=5) :: '-2.1', 'floor'], &
        0.0_dp, 0.0_dp, 0.0_dp, 0.0_dp), tol, 'floor(-2.1) is -3')
    call assert_real_close(3.0_dp, run([character(len=4) :: '2.1', 'ceil'], &
        0.0_dp, 0.0_dp, 0.0_dp, 0.0_dp), tol, 'ceil(2.1) is 3')
    call assert_real_close(-2.0_dp, run([character(len=4) :: '-2.7', 'ceil'], &
        0.0_dp, 0.0_dp, 0.0_dp, 0.0_dp), tol, 'ceil(-2.7) is -2')
    call assert_real_close(0.25_dp, run([character(len=5) :: '2.25', 'fract'], &
        0.0_dp, 0.0_dp, 0.0_dp, 0.0_dp), tol, 'fract(2.25) is 0.25')
    call assert_real_close(0.75_dp, run([character(len=5) :: '-1.25', 'fract'], &
        0.0_dp, 0.0_dp, 0.0_dp, 0.0_dp), tol, 'fract(-1.25) is 0.75')

    ! ---- binary functions ----
    call assert_real_close(3.0_dp, run([character(len=3) :: '3', '7', 'min'], &
        0.0_dp, 0.0_dp, 0.0_dp, 0.0_dp), tol, 'min(3,7) is 3')
    call assert_real_close(7.0_dp, run([character(len=3) :: '3', '7', 'max'], &
        0.0_dp, 0.0_dp, 0.0_dp, 0.0_dp), tol, 'max(3,7) is 7')
    call assert_real_close(0.0_dp, run([character(len=4) :: '0.5', '0.4', 'step'], &
        0.0_dp, 0.0_dp, 0.0_dp, 0.0_dp), tol, 'step(0.5, 0.4) is 0')
    call assert_real_close(1.0_dp, run([character(len=4) :: '0.5', '0.5', 'step'], &
        0.0_dp, 0.0_dp, 0.0_dp, 0.0_dp), tol, 'step(0.5, 0.5) is 1 (x >= edge)')
    call assert_real_close(1.0_dp, run([character(len=4) :: '0.5', '0.6', 'step'], &
        0.0_dp, 0.0_dp, 0.0_dp, 0.0_dp), tol, 'step(0.5, 0.6) is 1')
    call assert_real_close(8.0_dp, run([character(len=3) :: '2', '3', 'pow'], &
        0.0_dp, 0.0_dp, 0.0_dp, 0.0_dp), tol, 'pow(2,3) is 8')
    call assert_real_close(8.0_dp, run([character(len=1) :: '2', '3', '^'], &
        0.0_dp, 0.0_dp, 0.0_dp, 0.0_dp), tol, '2^3 is 8')
    call assert_real_close(-8.0_dp, run([character(len=3) :: '-2', '3', 'pow'], &
        0.0_dp, 0.0_dp, 0.0_dp, 0.0_dp), tol, 'pow(-2,3) is -8 (integer exp)')
    call assert_real_close(0.0_dp, run([character(len=4) :: '-2', '0.5', 'pow'], &
        0.0_dp, 0.0_dp, 0.0_dp, 0.0_dp), tol, 'pow(-2,0.5) is guarded to 0')
    call assert_real_close(1.0_dp, run([character(len=3) :: '0', '0', 'pow'], &
        0.0_dp, 0.0_dp, 0.0_dp, 0.0_dp), tol, 'pow(0,0) is 1')
    call assert_real_close(0.0_dp, run([character(len=3) :: '0', '-1', 'pow'], &
        0.0_dp, 0.0_dp, 0.0_dp, 0.0_dp), tol, 'pow(0,-1) is guarded to 0')
    call assert_real_close(0.0_dp, run([character(len=3) :: '0', '2', 'pow'], &
        0.0_dp, 0.0_dp, 0.0_dp, 0.0_dp), tol, 'pow(0,2) is 0')

    ! ---- ternary functions ----
    call assert_real_close(1.0_dp, run([character(len=5) :: &
        '5', '0', '1', 'clamp'], 0.0_dp, 0.0_dp, 0.0_dp, 0.0_dp), tol, &
        'clamp(5,0,1) is 1')
    call assert_real_close(0.0_dp, run([character(len=5) :: &
        '-5', '0', '1', 'clamp'], 0.0_dp, 0.0_dp, 0.0_dp, 0.0_dp), tol, &
        'clamp(-5,0,1) is 0')
    call assert_real_close(0.5_dp, run([character(len=5) :: &
        '0.5', '0', '1', 'clamp'], 0.0_dp, 0.0_dp, 0.0_dp, 0.0_dp), tol, &
        'clamp(0.5,0,1) is 0.5')
    call assert_real_close(2.5_dp, run([character(len=4) :: &
        '0', '10', '0.25', 'mix'], 0.0_dp, 0.0_dp, 0.0_dp, 0.0_dp), tol, &
        'mix(0,10,0.25) is 2.5')
    call assert_real_close(2.0_dp, run([character(len=3) :: &
        '2', '4', '0', 'mix'], 0.0_dp, 0.0_dp, 0.0_dp, 0.0_dp), tol, &
        'mix(2,4,0) is 2')
    call assert_real_close(4.0_dp, run([character(len=3) :: &
        '2', '4', '1', 'mix'], 0.0_dp, 0.0_dp, 0.0_dp, 0.0_dp), tol, &
        'mix(2,4,1) is 4')

    ! ---- guarded division / modulo ----
    call assert_real_close(0.0_dp, run([character(len=1) :: '1', '0', '/'], &
        0.0_dp, 0.0_dp, 0.0_dp, 0.0_dp), tol, '1/0 is guarded to 0')
    call assert_real_close(0.0_dp, run([character(len=1) :: '0', '0', '/'], &
        0.0_dp, 0.0_dp, 0.0_dp, 0.0_dp), tol, '0/0 is guarded to 0')
    call assert_real_close(2.0_dp, run([character(len=1) :: '5', '3', '%'], &
        0.0_dp, 0.0_dp, 0.0_dp, 0.0_dp), tol, 'mod(5,3) is 2')
    call assert_real_close(-2.0_dp, run([character(len=2) :: '-5', '3', '%'], &
        0.0_dp, 0.0_dp, 0.0_dp, 0.0_dp), tol, &
        'mod(-5,3) is -2 (Fortran mod: sign of dividend)')
    call assert_real_close(0.0_dp, run([character(len=1) :: '5', '0', '%'], &
        0.0_dp, 0.0_dp, 0.0_dp, 0.0_dp), tol, 'mod(5,0) is guarded to 0')

    ! ---- lighting expression: c * (0.25 + 0.75*ndl) ----
    call shader_parse([character(len=4) :: &
        'c', '0.25', '0.75', 'ndl', '*', '+', '*'], prog, ok, errmsg)
    call assert_true(ok, 'lighting expr parses ok')
    call assert_real_close(0.8_dp, shader_eval(prog, 0.8_dp, 0.0_dp, 0.0_dp, &
        0.0_dp, 0.0_dp, 0.0_dp, 0.0_dp, 0.0_dp, 0.0_dp, 1.0_dp, 0.0_dp), tol, &
        'lighting expr at ndl=1 returns c')
    call assert_real_close(0.2_dp, shader_eval(prog, 0.8_dp, 0.0_dp, 0.0_dp, &
        0.0_dp, 0.0_dp, 0.0_dp, 0.0_dp, 0.0_dp, 0.0_dp, 0.0_dp, 0.0_dp), tol, &
        'lighting expr at ndl=0 returns 0.25*c')
    call assert_real_close(0.5_dp, shader_eval(prog, 0.8_dp, 0.0_dp, 0.0_dp, &
        0.0_dp, 0.0_dp, 0.0_dp, 0.0_dp, 0.0_dp, 0.0_dp, 0.5_dp, 0.0_dp), tol, &
        'lighting expr at ndl=0.5 returns 0.625*c')

    ! ---- checker expression: step(0.5, fract((x+y)*2)) * c ----
    call shader_parse([character(len=5) :: &
        '0.5', 'x', 'y', '+', '2', '*', 'fract', 'step', 'c', '*'], &
        prog, ok, errmsg)
    call assert_true(ok, 'checker expr parses ok')
    call assert_real_close(0.0_dp, shader_eval(prog, 0.9_dp, 0.0_dp, 0.0_dp, &
        0.0_dp, 0.0_dp, 0.0_dp, 0.0_dp, 0.0_dp, 0.0_dp, 0.0_dp, 0.0_dp), tol, &
        'checker at (0,0) is 0')
    call assert_real_close(0.9_dp, shader_eval(prog, 0.9_dp, 0.0_dp, 0.0_dp, &
        0.0_dp, 0.3_dp, 0.0_dp, 0.0_dp, 0.0_dp, 0.0_dp, 0.0_dp, 0.0_dp), tol, &
        'checker at (0.3,0) is c')
    call assert_real_close(0.9_dp, shader_eval(prog, 0.9_dp, 0.0_dp, 0.0_dp, &
        0.0_dp, 0.25_dp, 0.0_dp, 0.0_dp, 0.0_dp, 0.0_dp, 0.0_dp, 0.0_dp), tol, &
        'checker at (0.25,0) is c (fract = 0.5 boundary)')
    call assert_real_close(0.0_dp, shader_eval(prog, 0.9_dp, 0.0_dp, 0.0_dp, &
        0.0_dp, 0.1_dp, 0.1_dp, 0.0_dp, 0.0_dp, 0.0_dp, 0.0_dp, 0.0_dp), tol, &
        'checker at (0.1,0.1) is 0')

    ! ---- parse errors ----
    call shader_parse([character(len=5) :: 'bogus'], prog, ok, errmsg)
    call assert_false(ok, 'unknown token "bogus" fails to parse')
    call assert_true(len_trim(errmsg) > 0, 'unknown token sets errmsg')
    call shader_parse([character(len=3) :: '1', 'foo'], prog, ok, errmsg)
    call assert_false(ok, 'unknown token after a valid token fails to parse')
    call shader_parse([character(len=1) :: '+'], prog, ok, errmsg)
    call assert_false(ok, 'binary op with empty stack underflows')
    call assert_true(len_trim(errmsg) > 0, 'underflow sets errmsg')
    call shader_parse([character(len=1) :: '1', '+'], prog, ok, errmsg)
    call assert_false(ok, 'binary op with one operand underflows')
    call shader_parse([character(len=3) :: 'sin'], prog, ok, errmsg)
    call assert_false(ok, 'unary function with empty stack underflows')
    call shader_parse([character(len=5) :: '1', '2', 'clamp'], prog, ok, errmsg)
    call assert_false(ok, 'ternary function with two operands underflows')
    do i = 1, size(many_tokens)
        many_tokens(i) = '1'
    end do
    call shader_parse(many_tokens, prog, ok, errmsg)
    call assert_false(ok, '65 pushes overflow the 64-deep value stack')

    call test_summary()

contains

    ! Parse tokens (assumed valid) and evaluate with r=g=b=z=u=v=t=0;
    ! only c, x, y and ndl vary between the simple cases above.
    function run(tokens, cv, xv, yv, ndlv) result(val)
        character(len=*), intent(in) :: tokens(:)
        real(dp), intent(in) :: cv, xv, yv, ndlv
        real(dp) :: val
        type(ShaderProg) :: p
        logical :: pok
        character(len=256) :: perr

        call shader_parse(tokens, p, pok, perr)
        if (.not. pok) then
            val = -999999.0_dp
            return
        end if
        val = shader_eval(p, cv, 0.0_dp, 0.0_dp, 0.0_dp, xv, yv, 0.0_dp, &
                          0.0_dp, 0.0_dp, ndlv, 0.0_dp)
    end function run

end program test_shader
