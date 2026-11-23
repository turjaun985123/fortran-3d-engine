! psnr.f90 -- Forge3D v3.0 Phase 2 (ADR-1): standalone PPM
! comparison tool for the v3 golden registry (docs/V3-GOLDENS.md).
!
!   psnr <a.ppm> <b.ppm> [--threshold DB]
!
! Reads P3 (ASCII) and P6 (binary) PPMs -- the engine writes P3;
! both are accepted so goldens can be compared against renders
! from any source.  The two images must have identical dimensions.
!
! Prints exactly one line:
!   PSNR: <db> dB  MAXDIFF: <n>
! with <db> rendered as "inf" when the images are identical.
! PSNR uses each file's samples as stored and file A's maxval as
! the peak.  MAXDIFF is the largest absolute per-sample difference.
!
! Exit status: 0 when PSNR >= threshold (or the images are
! identical, or no threshold was given), 1 when PSNR is below the
! threshold, 2 on usage / IO / format errors.
!
! Build: gfortran -O2 tools/psnr.f90 -o psnr
program psnr
  use, intrinsic :: iso_fortran_env, only: int64, real64
  implicit none

  character(len=1024) :: path_a, path_b, arg
  real(real64) :: threshold
  logical :: has_threshold
  integer :: nargs, i
  integer, allocatable :: img_a(:), img_b(:)
  integer :: wa, ha, maxa, wb, hb, maxb
  logical :: ok
  character(len=256) :: errmsg
  real(real64) :: mse, psnr_db, sumsq
  integer(int64) :: maxdiff, d, k, nsamp
  character(len=32) :: db_str

  nargs = command_argument_count()
  if (nargs < 2) call usage_error('expected two PPM paths')
  call get_command_argument(1, path_a)
  call get_command_argument(2, path_b)
  has_threshold = .false.
  threshold = 0.0_real64
  i = 3
  do while (i <= nargs)
    call get_command_argument(i, arg)
    if (trim(arg) == '--threshold') then
      if (i + 1 > nargs) call usage_error('--threshold needs a value')
      call get_command_argument(i + 1, arg)
      block
        integer :: ios
        read (arg, *, iostat=ios) threshold
        if (ios /= 0) call usage_error('bad --threshold value')
      end block
      has_threshold = .true.
      i = i + 2
    else
      call usage_error('unknown argument: ' // trim(arg))
    end if
  end do

  call read_ppm(trim(path_a), img_a, wa, ha, maxa, ok, errmsg)
  if (.not. ok) then
    write (0, '(A)') 'psnr: ' // trim(errmsg)
    call exit(2)
  end if
  call read_ppm(trim(path_b), img_b, wb, hb, maxb, ok, errmsg)
  if (.not. ok) then
    write (0, '(A)') 'psnr: ' // trim(errmsg)
    call exit(2)
  end if
  if (wa /= wb .or. ha /= hb) then
    write (0, '(A,I0,A,I0,A,I0,A,I0,A)') 'psnr: dimension mismatch: ', &
      wa, 'x', ha, ' vs ', wb, 'x', hb
    call exit(2)
  end if

  nsamp = int(wa, int64) * int(ha, int64) * 3_int64
  sumsq = 0.0_real64
  maxdiff = 0_int64
  do k = 1, nsamp
    d = int(img_a(k) - img_b(k), int64)
    if (abs(d) > maxdiff) maxdiff = abs(d)
    sumsq = sumsq + real(d * d, real64)
  end do

  if (maxdiff == 0_int64) then
    print '(A,I0)', 'PSNR: inf dB  MAXDIFF: ', maxdiff
    call exit(0)
  end if
  mse = sumsq / real(nsamp, real64)
  psnr_db = 10.0_real64 * log10(real(maxa, real64)**2 / mse)
  write (db_str, '(F0.2)') psnr_db
  print '(A,A,A,I0)', 'PSNR: ', trim(db_str), ' dB  MAXDIFF: ', maxdiff
  if (has_threshold .and. psnr_db < threshold) call exit(1)
  call exit(0)

contains

  subroutine usage_error(msg)
    character(len=*), intent(in) :: msg
    write (0, '(A)') 'psnr: ' // msg
    write (0, '(A)') 'usage: psnr <a.ppm> <b.ppm> [--threshold DB]'
    call exit(2)
  end subroutine usage_error

  ! Read a whole file into a byte array (stream access).
  subroutine read_bytes(path, bytes, ok, errmsg)
    character(len=*), intent(in) :: path
    integer, allocatable, intent(out) :: bytes(:)
    logical, intent(out) :: ok
    character(len=*), intent(out) :: errmsg
    integer :: u, ios, k
    integer(int64) :: fsize
    character(len=1), allocatable :: raw(:)
    ok = .false.
    errmsg = ''
    inquire (file=path, size=fsize, iostat=ios)
    if (ios /= 0 .or. fsize <= 0) then
      errmsg = 'cannot open file: ' // path
      return
    end if
    open (newunit=u, file=path, status='old', action='read', &
          access='stream', form='unformatted', iostat=ios)
    if (ios /= 0) then
      errmsg = 'cannot open file: ' // path
      return
    end if
    allocate (raw(fsize), bytes(fsize))
    read (u, iostat=ios) raw
    close (u)
    if (ios /= 0) then
      errmsg = 'cannot read file: ' // path
      return
    end if
    do k = 1, int(fsize)
      bytes(k) = iachar(raw(k))
    end do
    deallocate (raw)
    ok = .true.
  end subroutine read_bytes

  ! Next whitespace/comment-delimited token from bytes starting at
  ! pos (advanced past the token).  found=.false. at end of data.
  subroutine next_token(bytes, pos, tok, found)
    integer, intent(in) :: bytes(:)
    integer, intent(inout) :: pos
    character(len=:), allocatable, intent(out) :: tok
    logical, intent(out) :: found
    integer :: start, n, k
    n = size(bytes)
    found = .false.
    if (allocated(tok)) deallocate (tok)
    do while (pos <= n)
      if (bytes(pos) == iachar('#')) then
        do while (pos <= n .and. bytes(pos) /= 10)
          pos = pos + 1
        end do
      else if (bytes(pos) <= 32) then
        pos = pos + 1
      else
        exit
      end if
    end do
    if (pos > n) return
    start = pos
    do while (pos <= n .and. bytes(pos) > 32 .and. &
              bytes(pos) /= iachar('#'))
      pos = pos + 1
    end do
    allocate (character(len=pos - start) :: tok)
    do k = 1, len(tok)
      tok(k:k) = achar(bytes(start + k - 1))
    end do
    found = .true.
  end subroutine next_token

  subroutine read_ppm(path, img, w, h, maxval, ok, errmsg)
    character(len=*), intent(in) :: path
    integer, allocatable, intent(out) :: img(:)
    integer, intent(out) :: w, h, maxval
    logical, intent(out) :: ok
    character(len=*), intent(out) :: errmsg
    integer, allocatable :: bytes(:)
    character(len=:), allocatable :: tok
    logical :: found, binary
    integer :: pos, ios, k, nsamp, hi, lo

    ok = .false.
    errmsg = ''
    call read_bytes(path, bytes, ok, errmsg)
    if (.not. ok) return
    ok = .false.

    pos = 1
    call next_token(bytes, pos, tok, found)
    if (.not. found .or. (tok /= 'P3' .and. tok /= 'P6')) then
      errmsg = 'not a P3/P6 PPM: ' // path
      return
    end if
    binary = (tok == 'P6')
    call next_token(bytes, pos, tok, found)
    if (.not. found) then
      errmsg = 'truncated PPM header: ' // path
      return
    end if
    read (tok, *, iostat=ios) w
    if (ios /= 0) then
      errmsg = 'bad PPM width: ' // path
      return
    end if
    call next_token(bytes, pos, tok, found)
    if (.not. found) then
      errmsg = 'truncated PPM header: ' // path
      return
    end if
    read (tok, *, iostat=ios) h
    if (ios /= 0) then
      errmsg = 'bad PPM height: ' // path
      return
    end if
    call next_token(bytes, pos, tok, found)
    if (.not. found) then
      errmsg = 'truncated PPM header: ' // path
      return
    end if
    read (tok, *, iostat=ios) maxval
    if (ios /= 0 .or. maxval <= 0 .or. maxval > 65535) then
      errmsg = 'bad PPM maxval: ' // path
      return
    end if
    if (w <= 0 .or. h <= 0) then
      errmsg = 'bad PPM dimensions: ' // path
      return
    end if
    nsamp = w * h * 3
    allocate (img(nsamp))
    if (binary) then
      ! pos sits just past the maxval token; exactly one whitespace
      ! byte separates the header from the raster.
      if (pos <= size(bytes)) then
        if (bytes(pos) == 13 .and. pos + 1 <= size(bytes) .and. &
            bytes(pos + 1) == 10) then
          pos = pos + 2
        else
          pos = pos + 1
        end if
      end if
      if (maxval < 256) then
        if (pos + nsamp - 1 > size(bytes)) then
          errmsg = 'truncated P6 raster: ' // path
          return
        end if
        do k = 1, nsamp
          img(k) = bytes(pos + k - 1)
        end do
      else
        if (pos + 2 * nsamp - 1 > size(bytes)) then
          errmsg = 'truncated P6 raster: ' // path
          return
        end if
        do k = 1, nsamp
          hi = bytes(pos + 2 * (k - 1))
          lo = bytes(pos + 2 * (k - 1) + 1)
          img(k) = hi * 256 + lo
        end do
      end if
    else
      do k = 1, nsamp
        call next_token(bytes, pos, tok, found)
        if (.not. found) then
          errmsg = 'truncated P3 raster: ' // path
          return
        end if
        read (tok, *, iostat=ios) img(k)
        if (ios /= 0) then
          errmsg = 'bad P3 sample: ' // path
          return
        end if
      end do
    end if
    ok = .true.
  end subroutine read_ppm

end program psnr
