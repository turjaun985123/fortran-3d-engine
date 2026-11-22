! assert_utils.f90 -- minimal assertion helpers for Fortran test programs.
!
! Usage:
!   use test_assert
!   call assert_true(1 + 1 == 2, "addition works")
!   call test_summary()   ! prints PASS n/n, or FAIL k of n and stops with 1
module test_assert
    use, intrinsic :: iso_fortran_env, only: real64
    implicit none
    private

    public :: assert_true, assert_false, assert_int_eq, &
              assert_real_close, assert_vec3_close, test_summary

    integer, save :: total_count  = 0
    integer, save :: passed_count = 0
    integer, save :: failed_count = 0

contains

    subroutine record_result(ok, msg)
        logical, intent(in) :: ok
        character(len=*), intent(in) :: msg

        total_count = total_count + 1
        if (ok) then
            passed_count = passed_count + 1
            write(*, '(A, A)') 'ok   - ', msg
        else
            failed_count = failed_count + 1
            write(*, '(A, A)') 'FAIL - ', msg
        end if
    end subroutine record_result

    subroutine assert_true(cond, msg)
        logical, intent(in) :: cond
        character(len=*), intent(in) :: msg

        call record_result(cond, msg)
    end subroutine assert_true

    subroutine assert_false(cond, msg)
        logical, intent(in) :: cond
        character(len=*), intent(in) :: msg

        call record_result(.not. cond, msg)
    end subroutine assert_false

    subroutine assert_int_eq(a, b, msg)
        integer, intent(in) :: a, b
        character(len=*), intent(in) :: msg

        if (a == b) then
            call record_result(.true., msg)
        else
            call record_result(.false., msg)
            write(*, '(A, I0, A, I0)') '       expected: ', b, '  got: ', a
        end if
    end subroutine assert_int_eq

    subroutine assert_real_close(a, b, tol, msg)
        real(real64), intent(in) :: a, b, tol
        character(len=*), intent(in) :: msg

        if (abs(a - b) <= tol) then
            call record_result(.true., msg)
        else
            call record_result(.false., msg)
            write(*, '(A, ES24.16, A, ES24.16, A, ES24.16)') &
                '       expected: ', b, '  got: ', a, '  tol: ', tol
        end if
    end subroutine assert_real_close

    ! Kept separate so that math_3d is only used by the vec3 assertion;
    ! the scalar assertions above have no dependency on math_3d.
    subroutine assert_vec3_close(v1, v2, tol, msg)
        use math_3d, only: vec3
        type(vec3), intent(in) :: v1, v2
        real(real64), intent(in) :: tol
        character(len=*), intent(in) :: msg
        logical :: ok

        ok = abs(v1%x - v2%x) <= tol .and. &
             abs(v1%y - v2%y) <= tol .and. &
             abs(v1%z - v2%z) <= tol
        if (ok) then
            call record_result(.true., msg)
        else
            call record_result(.false., msg)
            write(*, '(A, 3ES24.16)') '       expected: ', v2%x, v2%y, v2%z
            write(*, '(A, 3ES24.16)') '       got:      ', v1%x, v1%y, v1%z
            write(*, '(A, ES24.16)')  '       tol:      ', tol
        end if
    end subroutine assert_vec3_close

    subroutine test_summary()
        if (failed_count == 0) then
            write(*, '(A, I0, A, I0)') 'PASS ', passed_count, '/', total_count
        else
            write(*, '(A, I0, A, I0)') 'FAIL ', failed_count, ' of ', total_count
            flush(6)
            stop 1
        end if
    end subroutine test_summary

end module test_assert
