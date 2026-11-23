! property_fmt.f90 -- DIRECT unit tests for the shortest-round-trip
! float formatter in compiler/src/f3dc_str.f90 (v3.0 Phase 6, C3).
!
! The native black-box layer (test_native_compiler.f90) never links
! compiler modules; this program is the one exception, and it links
! exactly one self-contained module:
!
!   gfortran -O2 -o property_fmt tests/native/property_fmt.f90 \
!       compiler/src/f3dc_str.f90
!
! (f3dc_str depends only on iso_fortran_env / ieee_arithmetic, so it
! compiles standalone -- verified against the shipped tree.)
!
! For every battery value x it asserts BOTH:
!   * fmt_real(x) equals the known Python repr(float) string, and
!   * parse(fmt_real(x)) == x bit-for-bit (transfer to int64).
! Plus fmt_int edges (0, -1, 42, int64 max, int64 min) and the
! nan / inf / -inf spellings (string check only; they do not parse
! back as numbers through the .f3d lexer by design).
!
! Prints "FMT RESULT: PASS (n checks)" or FAIL and stops 1.

program property_fmt
  use iso_fortran_env, only: int64, real64
  use ieee_arithmetic, only: ieee_value, ieee_quiet_nan, &
                             ieee_positive_inf, ieee_negative_inf
  use f3dc_str, only: fmt_real, fmt_int
  implicit none

  integer :: checks = 0, fails = 0
  real(real64) :: vals(10)
  character(len=24) :: expect(10)
  integer :: i
  real(real64) :: back
  integer(int64) :: xbits, bbits
  character(len=64) :: buf
  integer :: ios

  ! Battery (task-specified values).
  vals(1) = 0.1_real64
  expect(1) = '0.1'
  vals(2) = 1.0_real64 / 3.0_real64
  expect(2) = '0.3333333333333333'
  vals(3) = 3.141592653589793_real64
  expect(3) = '3.141592653589793'
  vals(4) = 1.0e300_real64
  expect(4) = '1e+300'
  ! 5e-324: the smallest positive subnormal (bit pattern 1).
  vals(5) = transfer(1_int64, 0.0_real64)
  expect(5) = '5e-324'
  vals(6) = 9007199254740992.0_real64  ! 2**53
  expect(6) = '9007199254740992.0'
  vals(7) = 0.5_real64
  expect(7) = '0.5'
  ! -0.0: sign bit only.
  vals(8) = transfer(ishft(1_int64, 63), 0.0_real64)
  expect(8) = '-0.0'
  vals(9) = 1.0e-7_real64
  expect(9) = '1e-07'
  vals(10) = 123456789.123456789_real64
  expect(10) = '123456789.12345679'

  do i = 1, 10
    checks = checks + 1
    if (fmt_real(vals(i)) /= trim(expect(i))) then
      fails = fails + 1
      write(*, '(A,I0,A,A,A,A)') '  FAIL repr case ', i, ': got "', &
        fmt_real(vals(i)), '" want "', trim(expect(i)) // '"'
      cycle
    end if
    checks = checks + 1
    buf = fmt_real(vals(i))
    read(buf, *, iostat=ios) back
    xbits = transfer(vals(i), 0_int64)
    bbits = transfer(back, 0_int64)
    if (ios /= 0 .or. bbits /= xbits) then
      fails = fails + 1
      write(*, '(A,I0,A)') '  FAIL round-trip case ', i, &
        ': parse(fmt_real(x)) /= x bit-for-bit'
    end if
  end do

  ! Non-finite spellings (string parity only).
  call expect_str(fmt_real(ieee_value(0.0_real64, ieee_quiet_nan)), &
                  'nan', 'nan')
  call expect_str(fmt_real(ieee_value(0.0_real64, ieee_positive_inf)), &
                  'inf', '+inf')
  call expect_str(fmt_real(ieee_value(0.0_real64, ieee_negative_inf)), &
                  '-inf', '-inf')
  call expect_str(fmt_real(0.0_real64), '0.0', 'zero')
  call expect_str(fmt_real(1.0_real64), '1.0', 'one')
  call expect_str(fmt_real(2.5e-5_real64), '2.5e-05', 'small exp')

  ! fmt_int edges.
  call expect_str(fmt_int(0_int64), '0', 'int 0')
  call expect_str(fmt_int(-1_int64), '-1', 'int -1')
  call expect_str(fmt_int(42_int64), '42', 'int 42')
  call expect_str(fmt_int(huge(0_int64)), '9223372036854775807', &
                  'int max')
  call expect_str(fmt_int(-huge(0_int64) - 1_int64), &
                  '-9223372036854775808', 'int min')

  if (fails == 0) then
    write(*, '(A,I0,A)') 'FMT RESULT: PASS (', checks, ' checks)'
  else
    write(*, '(A,I0,A,I0,A)') 'FMT RESULT: FAIL (', fails, &
      ' failures in ', checks, ' checks)'
    stop 1
  end if

contains

  subroutine expect_str(got, want, label)
    character(len=*), intent(in) :: got, want, label
    checks = checks + 1
    if (got /= want) then
      fails = fails + 1
      write(*, '(A,A,A,A,A,A)') '  FAIL ', label, ': got "', got, &
        '" want "', want // '"'
    end if
  end subroutine expect_str

end program property_fmt
