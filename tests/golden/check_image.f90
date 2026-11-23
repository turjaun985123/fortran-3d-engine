! Golden-image checker for P3 (ASCII) PPM files -- Fortran port of
! tests/golden/check_image.py.  Same CLI, same output, same exit codes:
!
!   check_image IMAGE.ppm [--expect-nonflat] [--expect-bg R G B]
!                         [--min-distinct N] [--hash] [--psnr OTHER.ppm]
!
! Exit codes: 0 = all requested expectations pass, 1 = an expectation
! failed, 2 = usage / IO / format error (including PSNR dimension
! mismatch).
!
! Canonical pixel bytes (for --hash): big-endian uint32 width, big-endian
! uint32 height, then the raw RGB bytes; the printed hash is the SHA-256
! hex digest of those bytes (SHA-256 implemented here per FIPS 180-4).

module check_image_mod
   use, intrinsic :: iso_fortran_env, only: int32, int64
   use, intrinsic :: iso_c_binding, only: c_int, c_char, c_ptr, c_null_char, &
                                          c_f_pointer, c_associated, c_int16_t
   implicit none
   private
   public :: read_ppm_file, sha256_hex, parse_int_str, repr_str, itoa, &
             term_columns

   integer(int64), parameter :: M32 = 4294967295_int64

   ! Tokenizer state (module-level, like a tiny scanner over the file bytes).
   character(len=:), allocatable :: mbuf
   integer :: mlen = 0
   integer :: mpos = 1

   interface
      function c_stat(path, buf) bind(C, name="stat")
         import :: c_int, c_char
         integer(c_int) :: c_stat
         character(kind=c_char), intent(in) :: path(*)
         integer(c_int), intent(out) :: buf(*)
      end function c_stat
      function c_errno_loc() bind(C, name="__errno_location")
         import :: c_ptr
         type(c_ptr) :: c_errno_loc
      end function c_errno_loc
      function c_strerror(errnum) bind(C, name="strerror")
         import :: c_int, c_ptr
         type(c_ptr) :: c_strerror
         integer(c_int), value :: errnum
      end function c_strerror
      function c_ioctl(fd, request, arg) bind(C, name="ioctl")
         import :: c_int, c_int16_t
         integer(c_int) :: c_ioctl
         integer(c_int), value :: fd
         integer(c_int), value :: request
         integer(c_int16_t), intent(out) :: arg(*)
      end function c_ioctl
   end interface

contains

   ! Terminal columns the way Python's shutil.get_terminal_size()
   ! finds them: $COLUMNS, else TIOCGWINSZ on stdout/stderr/stdin,
   ! else 80.
   function term_columns() result(cols)
      integer :: cols
      character(len=64) :: env
      integer :: st, fd
      integer(int64) :: v
      logical :: okc
      integer(c_int16_t) :: ws(4)
      integer, parameter :: fds(3) = [1, 2, 0]
      cols = 0
      call get_environment_variable('COLUMNS', env, status=st)
      if (st == 0) then
         call parse_int_str(trim(env), v, okc)
         if (okc .and. v > 0_int64 .and. v <= 1000000_int64) cols = int(v)
      end if
      if (cols <= 0) then
         do fd = 1, 3
            ws = 0_c_int16_t
            if (c_ioctl(int(fds(fd), c_int), int(21523, c_int), ws) == 0) then
               if (ws(2) > 0_c_int16_t) then
                  cols = int(ws(2))
                  exit
               end if
            end if
         end do
      end if
      if (cols <= 0) cols = 80
   end function term_columns

   ! ------------------------------------------------------------------
   ! Small helpers
   ! ------------------------------------------------------------------

   function itoa(v) result(s)
      integer(int64), intent(in) :: v
      character(len=:), allocatable :: s
      character(len=32) :: tmp
      write (tmp, '(I0)') v
      s = trim(tmp)
   end function itoa

   function hex2(b) result(s)
      integer, intent(in) :: b
      character(len=2) :: s
      character(len=16), parameter :: digs = '0123456789abcdef'
      s(1:1) = digs(mod(b/16, 16) + 1:mod(b/16, 16) + 1)
      s(2:2) = digs(mod(b, 16) + 1:mod(b, 16) + 1)
   end function hex2

   ! Python repr() of an ASCII string (single quotes unless the string
   ! contains a single quote and no double quote).
   function repr_str(str) result(out)
      character(len=*), intent(in) :: str
      character(len=:), allocatable :: out
      character :: q
      integer :: i, b
      if (index(str, "'") > 0 .and. index(str, '"') == 0) then
         q = '"'
      else
         q = "'"
      end if
      out = q
      do i = 1, len(str)
         b = ichar(str(i:i))
         if (str(i:i) == '\') then
            out = out // '\\'
         else if (str(i:i) == q) then
            out = out // '\' // q
         else if (b == 9) then
            out = out // '\t'
         else if (b == 10) then
            out = out // '\n'
         else if (b == 13) then
            out = out // '\r'
         else if (b < 32 .or. b == 127) then
            out = out // '\x' // hex2(b)
         else
            out = out // str(i:i)
         end if
      end do
      out = out // q
   end function repr_str

   ! Python int(str): optional sign, digits, single underscores between
   ! digits; surrounding whitespace ignored.  Value saturates at CAP so
   ! absurdly long digit strings cannot overflow.
   subroutine parse_int_str(str, val, ok)
      character(len=*), intent(in) :: str
      integer(int64), intent(out) :: val
      logical, intent(out) :: ok
      integer(int64), parameter :: CAP = 900000000000000000_int64
      integer :: i, j, n, sgn
      logical :: prev_digit, seen_digit
      ok = .false.
      val = 0_int64
      n = len(str)
      i = 1
      do while (i <= n)
         if (.not. is_ws(ichar(str(i:i)))) exit
         i = i + 1
      end do
      j = n
      do while (j >= i)
         if (.not. is_ws(ichar(str(j:j)))) exit
         j = j - 1
      end do
      if (j < i) return
      sgn = 1
      if (str(i:i) == '+') then
         i = i + 1
      else if (str(i:i) == '-') then
         sgn = -1
         i = i + 1
      end if
      if (i > j) return
      prev_digit = .false.
      seen_digit = .false.
      do while (i <= j)
         if (str(i:i) >= '0' .and. str(i:i) <= '9') then
            if (val <= CAP) val = val*10_int64 + int(ichar(str(i:i)) - ichar('0'), int64)
            if (val > CAP) val = CAP + 1_int64
            prev_digit = .true.
            seen_digit = .true.
         else if (str(i:i) == '_') then
            if (.not. prev_digit) return
            if (i >= j) return
            if (.not. (str(i + 1:i + 1) >= '0' .and. str(i + 1:i + 1) <= '9')) return
            prev_digit = .false.
         else
            return
         end if
         i = i + 1
      end do
      if (.not. seen_digit .or. .not. prev_digit) return
      val = int(sgn, int64)*val
      ok = .true.
   end subroutine parse_int_str

   logical function is_ws(b)
      integer, intent(in) :: b
      is_ws = (b == 32) .or. (b >= 9 .and. b <= 13) .or. (b >= 28 .and. b <= 31)
   end function is_ws

   logical function is_break(b)
      integer, intent(in) :: b
      is_break = (b == 10) .or. (b == 11) .or. (b == 12) .or. (b == 13) &
                 .or. (b == 28) .or. (b == 29) .or. (b == 30)
   end function is_break

   ! Advance the scanner to the next token.  '#' starts a comment that
   ! runs to the end of the line (Python strips it before splitting).
   function next_token(ts, tl) result(found)
      integer, intent(out) :: ts, tl
      logical :: found
      integer :: b
      found = .false.
      ts = 0
      tl = 0
      do while (mpos <= mlen)
         b = ichar(mbuf(mpos:mpos))
         if (b == ichar('#')) then
            mpos = mpos + 1
            do while (mpos <= mlen)
               if (is_break(ichar(mbuf(mpos:mpos)))) exit
               mpos = mpos + 1
            end do
         else if (is_ws(b)) then
            mpos = mpos + 1
         else
            exit
         end if
      end do
      if (mpos > mlen) return
      ts = mpos
      do while (mpos <= mlen)
         b = ichar(mbuf(mpos:mpos))
         if (is_ws(b) .or. b == ichar('#')) exit
         mpos = mpos + 1
      end do
      tl = mpos - ts
      found = .true.
   end function next_token

   ! ------------------------------------------------------------------
   ! SHA-256 (FIPS 180-4) over a byte string
   ! ------------------------------------------------------------------

   pure function rotr32(x, n) result(r)
      integer(int64), intent(in) :: x
      integer, intent(in) :: n
      integer(int64) :: r
      r = iand(ior(ishft(x, -n), ishft(x, 32 - n)), M32)
   end function rotr32

   subroutine sha256_hex(msg, hex)
      character(len=*), intent(in) :: msg
      character(len=64), intent(out) :: hex
      integer(int64), parameter :: K(0:63) = [ &
         int(z'428a2f98', int64), int(z'71374491', int64), &
         int(z'b5c0fbcf', int64), int(z'e9b5dba5', int64), &
         int(z'3956c25b', int64), int(z'59f111f1', int64), &
         int(z'923f82a4', int64), int(z'ab1c5ed5', int64), &
         int(z'd807aa98', int64), int(z'12835b01', int64), &
         int(z'243185be', int64), int(z'550c7dc3', int64), &
         int(z'72be5d74', int64), int(z'80deb1fe', int64), &
         int(z'9bdc06a7', int64), int(z'c19bf174', int64), &
         int(z'e49b69c1', int64), int(z'efbe4786', int64), &
         int(z'0fc19dc6', int64), int(z'240ca1cc', int64), &
         int(z'2de92c6f', int64), int(z'4a7484aa', int64), &
         int(z'5cb0a9dc', int64), int(z'76f988da', int64), &
         int(z'983e5152', int64), int(z'a831c66d', int64), &
         int(z'b00327c8', int64), int(z'bf597fc7', int64), &
         int(z'c6e00bf3', int64), int(z'd5a79147', int64), &
         int(z'06ca6351', int64), int(z'14292967', int64), &
         int(z'27b70a85', int64), int(z'2e1b2138', int64), &
         int(z'4d2c6dfc', int64), int(z'53380d13', int64), &
         int(z'650a7354', int64), int(z'766a0abb', int64), &
         int(z'81c2c92e', int64), int(z'92722c85', int64), &
         int(z'a2bfe8a1', int64), int(z'a81a664b', int64), &
         int(z'c24b8b70', int64), int(z'c76c51a3', int64), &
         int(z'd192e819', int64), int(z'd6990624', int64), &
         int(z'f40e3585', int64), int(z'106aa070', int64), &
         int(z'19a4c116', int64), int(z'1e376c08', int64), &
         int(z'2748774c', int64), int(z'34b0bcb5', int64), &
         int(z'391c0cb3', int64), int(z'4ed8aa4a', int64), &
         int(z'5b9cca4f', int64), int(z'682e6ff3', int64), &
         int(z'748f82ee', int64), int(z'78a5636f', int64), &
         int(z'84c87814', int64), int(z'8cc70208', int64), &
         int(z'90befffa', int64), int(z'a4506ceb', int64), &
         int(z'bef9a3f7', int64), int(z'c67178f2', int64)]
      integer(int64) :: hs(0:7), w(0:63)
      integer(int64) :: a, b, c, d, e, f, g, h, t1, t2, s0, s1, ch, maj
      integer(int64) :: bitlen
      integer, allocatable :: mb(:)
      integer :: n, nblocks, blk, i, t, hp
      character(len=16), parameter :: digs = '0123456789abcdef'

      hs = [int(z'6a09e667', int64), int(z'bb67ae85', int64), &
            int(z'3c6ef372', int64), int(z'a54ff53a', int64), &
            int(z'510e527f', int64), int(z'9b05688c', int64), &
            int(z'1f83d9ab', int64), int(z'5be0cd19', int64)]
      n = len(msg)
      nblocks = (n + 9 + 63)/64
      allocate (mb(0:nblocks*64 - 1))
      mb = 0
      do i = 1, n
         mb(i - 1) = ichar(msg(i:i))
      end do
      mb(n) = 128
      bitlen = int(n, int64)*8_int64
      do i = 0, 7
         mb(nblocks*64 - 8 + i) = int(iand(ishft(bitlen, -8*(7 - i)), 255_int64))
      end do

      do blk = 0, nblocks - 1
         do t = 0, 15
            w(t) = int(mb(blk*64 + 4*t), int64)*16777216_int64 &
                 + int(mb(blk*64 + 4*t + 1), int64)*65536_int64 &
                 + int(mb(blk*64 + 4*t + 2), int64)*256_int64 &
                 + int(mb(blk*64 + 4*t + 3), int64)
         end do
         do t = 16, 63
            s0 = ieor(ieor(rotr32(w(t - 15), 7), rotr32(w(t - 15), 18)), &
                      ishft(w(t - 15), -3))
            s1 = ieor(ieor(rotr32(w(t - 2), 17), rotr32(w(t - 2), 19)), &
                      ishft(w(t - 2), -10))
            w(t) = iand(w(t - 16) + s0 + w(t - 7) + s1, M32)
         end do
         a = hs(0); b = hs(1); c = hs(2); d = hs(3)
         e = hs(4); f = hs(5); g = hs(6); h = hs(7)
         do t = 0, 63
            s1 = ieor(ieor(rotr32(e, 6), rotr32(e, 11)), rotr32(e, 25))
            ch = ieor(iand(e, f), iand(ieor(e, M32), g))
            t1 = iand(h + s1 + ch + K(t) + w(t), M32)
            s0 = ieor(ieor(rotr32(a, 2), rotr32(a, 13)), rotr32(a, 22))
            maj = ieor(ieor(iand(a, b), iand(a, c)), iand(b, c))
            t2 = iand(s0 + maj, M32)
            h = g; g = f; f = e
            e = iand(d + t1, M32)
            d = c; c = b; b = a
            a = iand(t1 + t2, M32)
         end do
         hs(0) = iand(hs(0) + a, M32)
         hs(1) = iand(hs(1) + b, M32)
         hs(2) = iand(hs(2) + c, M32)
         hs(3) = iand(hs(3) + d, M32)
         hs(4) = iand(hs(4) + e, M32)
         hs(5) = iand(hs(5) + f, M32)
         hs(6) = iand(hs(6) + g, M32)
         hs(7) = iand(hs(7) + h, M32)
      end do

      hp = 1
      do i = 0, 7
         do t = 28, 0, -4
            hex(hp:hp) = digs(int(iand(ishft(hs(i), -t), 15_int64)) + 1: &
                              int(iand(ishft(hs(i), -t), 15_int64)) + 1)
            hp = hp + 1
         end do
      end do
      deallocate (mb)
   end subroutine sha256_hex

   ! ------------------------------------------------------------------
   ! PPM reading
   ! ------------------------------------------------------------------

   ! On success ok=.true. and w/h/pixels are set (pixels: raw RGB bytes,
   ! row-major, one character per byte).  On failure ok=.false. and
   ! errmsg holds the message (without the "error: " prefix), matching
   ! the Python checker's messages.
   subroutine read_ppm_file(path, w, h, pixels, errmsg, ok)
      character(len=*), intent(in) :: path
      integer(int64), intent(out) :: w, h
      character(len=:), allocatable, intent(out) :: pixels
      character(len=:), allocatable, intent(out) :: errmsg
      logical, intent(out) :: ok

      integer(c_int) :: sbuf(36)
      integer(c_int), pointer :: errp
      type(c_ptr) :: eptr, sptr
      character(kind=c_char), pointer :: serr(:)
      character(len=:), allocatable :: cpath, emsg
      integer :: u, ios, i, b, ts, tl
      integer(int64) :: fsize, maxval, expected, cnt, cap, v, num, q, r
      integer, allocatable :: sts(:), stl(:)
      integer :: hs_ts(4), hs_tl(4)
      logical :: found, pok

      ok = .false.
      w = 0_int64
      h = 0_int64
      errmsg = ''

      ! --- stat() first, so IO errors read like Python's OSError text.
      cpath = path // c_null_char
      if (c_stat(cpath, sbuf) /= 0) then
         eptr = c_errno_loc()
         call c_f_pointer(eptr, errp)
         sptr = c_strerror(errp)
         emsg = ''
         if (c_associated(sptr)) then
            call c_f_pointer(sptr, serr, [4096])
            i = 1
            do while (i <= 4096)
               if (serr(i) == c_null_char) exit
               emsg = emsg // serr(i)
               i = i + 1
            end do
         end if
         errmsg = '[Errno ' // trim(itoa(int(errp, int64))) // '] ' &
                  // emsg // ': ' // repr_str(path)
         return
      end if
      ! S_ISDIR: file type bits of st_mode (offset 24) equal 0040000.
      if (iand(int(sbuf(7), int64), 61440_int64) == 16384_int64) then
         errmsg = '[Errno 21] Is a directory: ' // repr_str(path)
         return
      end if

      inquire (file=path, size=fsize)
      if (fsize < 0_int64) fsize = 0_int64
      open (newunit=u, file=path, access='stream', form='unformatted', &
            status='old', action='read', iostat=ios)
      if (ios /= 0) then
         errmsg = '[Errno 13] Permission denied: ' // repr_str(path)
         return
      end if
      if (allocated(mbuf)) deallocate (mbuf)
      allocate (character(len=max(int(fsize), 1)) :: mbuf)
      mlen = int(fsize)
      if (fsize > 0_int64) then
         read (u, iostat=ios) mbuf
         if (ios /= 0) then
            close (u)
            errmsg = '[Errno 5] Input/output error: ' // repr_str(path)
            return
         end if
      end if
      close (u)

      ! --- Python decodes the file as strict ASCII before tokenizing.
      do i = 1, mlen
         b = ichar(mbuf(i:i))
         if (b >= 128) then
            errmsg = "'ascii' codec can't decode byte 0x" // hex2(b) &
                     // ' in position ' // trim(itoa(int(i - 1, int64))) &
                     // ': ordinal not in range(128)'
            return
         end if
      end do

      ! --- Header.
      mpos = 1
      do i = 1, 4
         found = next_token(ts, tl)
         if (.not. found) then
            errmsg = 'PPM too short: missing header'
            return
         end if
         hs_ts(i) = ts
         hs_tl(i) = tl
      end do
      if (hs_tl(1) /= 2 .or. mbuf(hs_ts(1):hs_ts(1) + 1) /= 'P3') then
         errmsg = 'not a P3 PPM (magic ' &
                  // repr_str(mbuf(hs_ts(1):hs_ts(1) + hs_tl(1) - 1)) // ')'
         return
      end if
      call parse_int_str(mbuf(hs_ts(2):hs_ts(2) + hs_tl(2) - 1), w, pok)
      if (pok) call parse_int_str(mbuf(hs_ts(3):hs_ts(3) + hs_tl(3) - 1), h, pok)
      if (pok) call parse_int_str(mbuf(hs_ts(4):hs_ts(4) + hs_tl(4) - 1), &
                                  maxval, pok)
      if (.not. pok) then
         errmsg = 'non-integer width/height/maxval in PPM header'
         return
      end if
      if (w <= 0_int64 .or. h <= 0_int64) then
         errmsg = 'PPM dimensions must be positive'
         return
      end if
      if (maxval <= 0_int64 .or. maxval > 65535_int64) then
         errmsg = 'PPM maxval out of range: ' // trim(itoa(maxval))
         return
      end if

      ! --- Sample tokens: count them all, keep spans for the first
      ! `expected` ones (any more is an error anyway).
      if (w > 1000000000_int64 .or. h > 1000000000_int64 &
          .or. w*h > 3000000000_int64) then
         expected = 9000000000000000000_int64
      else
         expected = w*h*3_int64
      end if
      cap = min(expected, int(mlen, int64))
      allocate (sts(max(int(cap), 1)), stl(max(int(cap), 1)))
      cnt = 0_int64
      do
         found = next_token(ts, tl)
         if (.not. found) exit
         cnt = cnt + 1_int64
         if (cnt <= cap) then
            sts(int(cnt)) = ts
            stl(int(cnt)) = tl
         end if
      end do
      if (cnt < expected) then
         errmsg = 'PPM truncated: expected ' // trim(itoa(expected)) &
                  // ' samples, got ' // trim(itoa(cnt))
         deallocate (sts, stl)
         return
      end if
      if (cnt > expected) then
         errmsg = 'PPM has extra data: expected ' // trim(itoa(expected)) &
                  // ' samples, got ' // trim(itoa(cnt))
         deallocate (sts, stl)
         return
      end if

      allocate (character(len=int(expected)) :: pixels)
      do i = 1, int(expected)
         call parse_int_str(mbuf(sts(i):sts(i) + stl(i) - 1), v, pok)
         if (.not. pok) then
            errmsg = 'non-integer sample ' &
                     // repr_str(mbuf(sts(i):sts(i) + stl(i) - 1)) // ' in PPM'
            deallocate (sts, stl)
            return
         end if
         if (v < 0_int64 .or. v > maxval) then
            errmsg = 'sample ' // trim(itoa(v)) // ' out of range 0..' &
                     // trim(itoa(maxval))
            deallocate (sts, stl)
            return
         end if
         if (maxval == 255_int64) then
            q = v
         else
            ! round(v * 255 / maxval), ties to even (Python round()).
            num = v*255_int64
            q = num/maxval
            r = mod(num, maxval)
            if (2_int64*r > maxval) then
               q = q + 1_int64
            else if (2_int64*r == maxval .and. mod(q, 2_int64) == 1_int64) then
               q = q + 1_int64
            end if
         end if
         pixels(i:i) = achar(int(q))
      end do
      deallocate (sts, stl)
      ok = .true.
   end subroutine read_ppm_file

end module check_image_mod


program check_image
   use, intrinsic :: iso_fortran_env, only: int64, output_unit, error_unit
   use check_image_mod, only: read_ppm_file, sha256_hex, parse_int_str, &
                              repr_str, itoa, term_columns
   implicit none

   integer :: nargs, i, alen, astat, eq
   character(len=8192) :: raw
   character(len=:), allocatable :: arg, name, inline_val, nxt
   logical :: has_inline

   ! CLI state
   logical :: expect_nonflat = .false., want_hash = .false.
   logical :: has_bg = .false., has_min_distinct = .false., has_psnr = .false.
   logical :: has_image = .false., end_opts = .false.
   integer(int64) :: bgv(3) = 0_int64, min_distinct = 0_int64
   character(len=:), allocatable :: image_path, psnr_path
   character(len=16384) :: unrec = ''
   integer :: unrec_len = 0

   ! Image state
   integer(int64) :: w, h, w2, h2
   character(len=:), allocatable :: pixels, pixels2, errmsg
   logical :: ok
   integer :: npix, j, distinct, bestcount, bestfirst, bestkey, effbg
   integer :: run_first, allbg_count
   integer(int64) :: key64
   integer, allocatable :: keys(:), idxs(:)
   logical :: nonflat
   character(len=64) :: hex
   character(len=:), allocatable :: canon
   character(len=256) :: psnr_str
   real(8) :: mse, psnr_val, dsum
   integer :: nfail
   character(len=512) :: fail1 = '', fail2 = '', fail3 = ''
   integer(int64) :: ival
   logical :: pok

   nargs = command_argument_count()
   i = 1
   do while (i <= nargs)
      call get_arg(i, arg)
      if (.not. end_opts .and. arg == '--') then
         end_opts = .true.
      else if (.not. end_opts .and. is_option_token(arg)) then
         if (arg(1:2) == '--') then
            eq = index(arg, '=')
            has_inline = eq > 0
            if (has_inline) then
               name = arg(1:eq - 1)
               inline_val = arg(eq + 1:)
            else
               name = arg
               inline_val = ''
            end if
            select case (name)
            case ('--help')
               call print_help()
               call exit(0)
            case ('--expect-nonflat')
               if (has_inline) call usage_error( &
                  'argument --expect-nonflat: ignored explicit argument ' &
                  // repr_str(inline_val))
               expect_nonflat = .true.
            case ('--hash')
               if (has_inline) call usage_error( &
                  'argument --hash: ignored explicit argument ' &
                  // repr_str(inline_val))
               want_hash = .true.
            case ('--expect-bg')
               block
                  integer :: nv, k
                  character(len=:), allocatable :: vs
                  nv = 0
                  has_bg = .true.
                  ! argparse never combines an '=' value with following
                  ! arguments for nargs=3; it errors out instead.
                  if (has_inline) call usage_error( &
                     'argument --expect-bg: expected 3 arguments')
                  do while (nv < 3)
                     if (i + 1 > nargs) call usage_error( &
                        'argument --expect-bg: expected 3 arguments')
                     call get_arg(i + 1, vs)
                     if (is_option_like(vs)) call usage_error( &
                        'argument --expect-bg: expected 3 arguments')
                     i = i + 1
                     nv = nv + 1
                     call parse_cli_int('--expect-bg', vs, bgv(nv))
                  end do
                  k = nv  ! silence unused warnings in some compilers
               end block
            case ('--min-distinct')
               has_min_distinct = .true.
               call take_value(i, '--min-distinct', has_inline, inline_val, nxt)
               call parse_cli_int('--min-distinct', nxt, min_distinct)
            case ('--psnr')
               has_psnr = .true.
               call take_value(i, '--psnr', has_inline, inline_val, nxt)
               psnr_path = nxt
            case default
               call add_unrec(arg)
            end select
         else
            if (arg == '-h') then
               call print_help()
               call exit(0)
            end if
            call add_unrec(arg)
         end if
      else
         if (.not. has_image) then
            image_path = arg
            has_image = .true.
         else
            call add_unrec(arg)
         end if
      end if
      i = i + 1
   end do

   if (unrec_len > 0) call usage_error('unrecognized arguments: ' &
                                       // unrec(1:unrec_len))
   if (.not. has_image) call usage_error('the following arguments are ' &
                                         // 'required: image')
   if (has_bg .and. any(bgv < 0_int64 .or. bgv > 255_int64)) &
      call usage_error('--expect-bg values must be in 0..255')
   if (has_min_distinct .and. min_distinct < 0_int64) &
      call usage_error('--min-distinct must be >= 0')

   ! --- Read and check the image.
   call read_ppm_file(image_path, w, h, pixels, errmsg, ok)
   if (.not. ok) then
      write (error_unit, '(A)') 'error: ' // errmsg
      flush (error_unit)
      call exit(2)
   end if

   npix = int(w*h)
   allocate (keys(npix), idxs(npix))
   do j = 1, npix
      keys(j) = ichar(pixels(3*j - 2:3*j - 2))*65536 &
              + ichar(pixels(3*j - 1:3*j - 1))*256 &
              + ichar(pixels(3*j:3*j))
      idxs(j) = j
   end do
   call sort_pairs(keys, idxs, npix)

   distinct = 0
   bestcount = -1
   bestfirst = huge(0)
   bestkey = 0
   j = 1
   do while (j <= npix)
      i = j
      run_first = idxs(j)
      do while (i <= npix)
         if (keys(i) /= keys(j)) exit
         i = i + 1
      end do
      distinct = distinct + 1
      if (i - j > bestcount .or. &
          (i - j == bestcount .and. run_first < bestfirst)) then
         bestcount = i - j
         bestfirst = run_first
         bestkey = keys(j)
      end if
      j = i
   end do

   if (has_bg) then
      effbg = int(bgv(1))*65536 + int(bgv(2))*256 + int(bgv(3))
   else
      effbg = bestkey
   end if
   allbg_count = count(keys == effbg)
   nonflat = distinct >= 2 .and. allbg_count /= npix

   write (output_unit, '(A)') 'size: ' // trim(itoa(w)) // 'x' // trim(itoa(h))
   write (output_unit, '(A)') 'distinct: ' // trim(itoa(int(distinct, int64)))
   if (nonflat) then
      write (output_unit, '(A)') 'nonflat: yes'
   else
      write (output_unit, '(A)') 'nonflat: no'
   end if
   if (want_hash) then
      allocate (character(len=8 + len(pixels)) :: canon)
      key64 = w
      canon(1:1) = achar(int(iand(ishft(key64, -24), 255_int64)))
      canon(2:2) = achar(int(iand(ishft(key64, -16), 255_int64)))
      canon(3:3) = achar(int(iand(ishft(key64, -8), 255_int64)))
      canon(4:4) = achar(int(iand(key64, 255_int64)))
      key64 = h
      canon(5:5) = achar(int(iand(ishft(key64, -24), 255_int64)))
      canon(6:6) = achar(int(iand(ishft(key64, -16), 255_int64)))
      canon(7:7) = achar(int(iand(ishft(key64, -8), 255_int64)))
      canon(8:8) = achar(int(iand(key64, 255_int64)))
      canon(9:) = pixels
      call sha256_hex(canon, hex)
      deallocate (canon)
      write (output_unit, '(A)') 'sha256: ' // hex
   end if

   nfail = 0
   if (expect_nonflat .and. .not. nonflat) then
      nfail = nfail + 1
      fail1 = 'expected non-flat image'
   end if
   if (has_bg) then
      if (bgv(1) /= int(bestkey/65536, int64) .or. &
          bgv(2) /= int(mod(bestkey/256, 256), int64) .or. &
          bgv(3) /= int(mod(bestkey, 256), int64)) then
         nfail = nfail + 1
         fail2 = 'expected bg (' // trim(itoa(bgv(1))) // ', ' &
                 // trim(itoa(bgv(2))) // ', ' // trim(itoa(bgv(3))) &
                 // '), got (' // trim(itoa(int(bestkey/65536, int64))) &
                 // ', ' // trim(itoa(int(mod(bestkey/256, 256), int64))) &
                 // ', ' // trim(itoa(int(mod(bestkey, 256), int64))) // ')'
      end if
   end if
   if (has_min_distinct .and. int(distinct, int64) < min_distinct) then
      nfail = nfail + 1
      fail3 = 'expected >= ' // trim(itoa(min_distinct)) &
              // ' distinct colours, got ' // trim(itoa(int(distinct, int64)))
   end if

   if (has_psnr) then
      call read_ppm_file(psnr_path, w2, h2, pixels2, errmsg, ok)
      if (.not. ok) then
         flush (output_unit)
         write (error_unit, '(A)') 'error: ' // errmsg
         flush (error_unit)
         call exit(2)
      end if
      if (w2 /= w .or. h2 /= h) then
         flush (output_unit)
         write (error_unit, '(A)') 'error: dimension mismatch: ' &
            // trim(itoa(w)) // 'x' // trim(itoa(h)) // ' vs ' &
            // trim(itoa(w2)) // 'x' // trim(itoa(h2))
         flush (error_unit)
         call exit(2)
      end if
      if (pixels == pixels2) then
         write (output_unit, '(A)') 'psnr: inf'
      else
         dsum = 0.0d0
         do j = 1, len(pixels)
            dsum = dsum + real(ichar(pixels(j:j)) - ichar(pixels2(j:j)), 8)**2
         end do
         mse = dsum/real(len(pixels), 8)
         if (mse == 0.0d0) then
            write (output_unit, '(A)') 'psnr: inf'
         else
            psnr_val = 10.0d0*log10(255.0d0**2/mse)
            write (psnr_str, '(F0.4)') psnr_val
            write (output_unit, '(A)') 'psnr: ' // trim(psnr_str)
         end if
      end if
   end if

   if (len_trim(fail1) > 0) write (error_unit, '(A)') 'FAIL: ' // trim(fail1)
   if (len_trim(fail2) > 0) write (error_unit, '(A)') 'FAIL: ' // trim(fail2)
   if (len_trim(fail3) > 0) write (error_unit, '(A)') 'FAIL: ' // trim(fail3)
   flush (output_unit)
   flush (error_unit)
   if (nfail > 0) then
      call exit(1)
   else
      call exit(0)
   end if

contains

   subroutine get_arg(k, s)
      integer, intent(in) :: k
      character(len=:), allocatable, intent(out) :: s
      call get_command_argument(k, raw, length=alen, status=astat)
      allocate (character(len=alen) :: s)
      s = raw(1:alen)
   end subroutine get_arg

   logical function is_option_token(s)
      character(len=*), intent(in) :: s
      is_option_token = len(s) >= 2 .and. s(1:1) == '-'
   end function is_option_token

   ! Would argparse refuse to swallow this token as an option value?
   logical function is_option_like(s)
      character(len=*), intent(in) :: s
      integer :: k
      logical :: numlike
      is_option_like = .false.
      if (len(s) < 2 .or. s(1:1) /= '-') return
      if (s == '-') return
      ! Negative-number-like tokens are treated as values by argparse
      ! (this parser has no options that look like negative numbers).
      numlike = .true.
      if (len(s) >= 2 .and. s(2:2) >= '0' .and. s(2:2) <= '9') then
         do k = 2, len(s)
            if (.not. (s(k:k) >= '0' .and. s(k:k) <= '9')) numlike = .false.
         end do
      else if (len(s) >= 3 .and. s(2:2) == '.' &
               .and. s(3:3) >= '0' .and. s(3:3) <= '9') then
         do k = 3, len(s)
            if (.not. (s(k:k) >= '0' .and. s(k:k) <= '9')) numlike = .false.
         end do
      else
         numlike = .false.
      end if
      is_option_like = .not. numlike
   end function is_option_like

   subroutine add_unrec(s)
      character(len=*), intent(in) :: s
      if (unrec_len > 0) then
         unrec(unrec_len + 1:unrec_len + 1) = ' '
         unrec_len = unrec_len + 1
      end if
      unrec(unrec_len + 1:unrec_len + len(s)) = s
      unrec_len = unrec_len + len(s)
   end subroutine add_unrec

   subroutine take_value(k, optname, has_inl, inl, val)
      integer, intent(inout) :: k
      character(len=*), intent(in) :: optname
      logical, intent(in) :: has_inl
      character(len=*), intent(in) :: inl
      character(len=:), allocatable, intent(out) :: val
      character(len=:), allocatable :: vs
      if (has_inl) then
         val = inl
         return
      end if
      if (k + 1 > nargs) call usage_error('argument ' // optname &
                                          // ': expected one argument')
      call get_arg(k + 1, vs)
      if (is_option_like(vs)) call usage_error('argument ' // optname &
                                               // ': expected one argument')
      k = k + 1
      val = vs
   end subroutine take_value

   subroutine parse_cli_int(optname, s, val)
      character(len=*), intent(in) :: optname, s
      integer(int64), intent(out) :: val
      logical :: ok2
      call parse_int_str(s, val, ok2)
      if (.not. ok2) call usage_error('argument ' // optname &
                                      // ': invalid int value: ' // repr_str(s))
   end subroutine parse_cli_int

   ! Wrapped usage lines, built with CPython argparse's exact
   ! _format_usage algorithm (get_lines over the optionals, then the
   ! positionals separately; text_width = terminal columns - 2).
   subroutine build_usage_lines(ulines, nulin)
      character(len=*), intent(out) :: ulines(:)
      integer, intent(out) :: nulin
      character(len=32) :: opt_parts(6), pos_parts(1), po(7), allp(7)
      character(len=22) :: indent22
      character(len=7) :: indent7
      integer :: utw, usage_len, k, saved
      opt_parts(1) = '[-h]'
      opt_parts(2) = '[--expect-nonflat]'
      opt_parts(3) = '[--expect-bg R G B]'
      opt_parts(4) = '[--min-distinct N]'
      opt_parts(5) = '[--hash]'
      opt_parts(6) = '[--psnr OTHER.ppm]'
      pos_parts(1) = 'image'
      utw = term_columns() - 2
      usage_len = len('check_image.py') + 1 + len_trim(pos_parts(1))
      do k = 1, 6
         usage_len = usage_len + len_trim(opt_parts(k)) + 1
      end do
      nulin = 0
      if (len('usage: ') + usage_len <= utw) then
         nulin = 1
         ulines(1) = 'check_image.py'
         do k = 1, 6
            ulines(1) = trim(ulines(1)) // ' ' // trim(opt_parts(k))
         end do
         ulines(1) = trim(ulines(1)) // ' image'
      else if (21.0 <= 0.75*real(utw)) then
         indent22 = repeat(' ', 22)
         po(1) = 'check_image.py'
         po(2:7) = opt_parts
         call gl(po, 7, indent22, .true., utw, ulines, nulin)
         call gl(pos_parts, 1, indent22, .false., utw, ulines, nulin)
      else
         indent7 = repeat(' ', 7)
         nulin = 1
         ulines(1) = 'check_image.py'
         saved = nulin
         allp(1:6) = opt_parts
         allp(7) = 'image'
         call gl(allp, 7, indent7, .false., utw, ulines, nulin)
         if (nulin - saved > 1) then
            nulin = saved
            call gl(opt_parts, 6, indent7, .false., utw, ulines, nulin)
            call gl(pos_parts, 1, indent7, .false., utw, ulines, nulin)
         end if
      end if
   end subroutine build_usage_lines

   subroutine gl(parts, np, indent, with_prefix, utw, ulines, nulin)
      character(len=32), intent(in) :: parts(:)
      integer, intent(in) :: np, utw
      character(len=*), intent(in) :: indent
      logical, intent(in) :: with_prefix
      character(len=*), intent(out) :: ulines(:)
      integer, intent(inout) :: nulin
      integer :: line_len, k, curl
      character(len=512) :: cur
      logical :: have
      if (with_prefix) then
         line_len = len('usage: ') - 1
      else
         line_len = len(indent) - 1
      end if
      cur = ''
      curl = 0
      have = .false.
      do k = 1, np
         if (line_len + 1 + len_trim(parts(k)) > utw .and. have) then
            nulin = nulin + 1
            if (nulin == 1) then
               ulines(nulin) = cur(1:curl)
            else
               ulines(nulin) = indent // cur(1:curl)
            end if
            cur = ''
            curl = 0
            have = .false.
            line_len = len(indent) - 1
         end if
         if (curl > 0) then
            curl = curl + 1
            cur(curl:curl) = ' '
         end if
         cur(curl + 1:curl + len_trim(parts(k))) = trim(parts(k))
         curl = curl + len_trim(parts(k))
         have = .true.
         line_len = line_len + len_trim(parts(k)) + 1
      end do
      if (have) then
         nulin = nulin + 1
         if (nulin == 1) then
            ulines(nulin) = cur(1:curl)
         else
            ulines(nulin) = indent // cur(1:curl)
         end if
      end if
   end subroutine gl

   subroutine write_usage(unit)
      integer, intent(in) :: unit
      character(len=512) :: ulines(24)
      integer :: nulin, k
      call build_usage_lines(ulines, nulin)
      do k = 1, nulin
         if (k == 1) then
            write (unit, '(A)') 'usage: ' // trim(ulines(k))
         else
            write (unit, '(A)') trim(ulines(k))
         end if
      end do
   end subroutine write_usage

   subroutine usage_error(msg)
      character(len=*), intent(in) :: msg
      call write_usage(error_unit)
      write (error_unit, '(A)') 'check_image.py: error: ' // msg
      flush (error_unit)
      call exit(2)
   end subroutine usage_error

   subroutine print_help()
      call write_usage(output_unit)
      write (output_unit, '(A)') ''
      write (output_unit, '(A)') 'Check a P3 PPM golden image.'
      write (output_unit, '(A)') ''
      write (output_unit, '(A)') 'positional arguments:'
      write (output_unit, '(A)') '  image              IMAGE.ppm to check'
      write (output_unit, '(A)') ''
      write (output_unit, '(A)') 'options:'
      write (output_unit, '(A)') '  -h, --help         show this help message and exit'
      write (output_unit, '(A)') '  --expect-nonflat   fail unless the image is non-flat'
      write (output_unit, '(A)') '  --expect-bg R G B  fail unless the background ' &
         // '(most frequent) colour is R G'
      write (output_unit, '(A)') '                     B'
      write (output_unit, '(A)') '  --min-distinct N   fail unless there are at ' &
         // 'least N distinct colours'
      write (output_unit, '(A)') '  --hash             print sha256 of the canonical pixel bytes'
      write (output_unit, '(A)') '  --psnr OTHER.ppm   print PSNR (dB) against OTHER.ppm'
      flush (output_unit)
   end subroutine print_help

   ! Stable bottom-up merge sort of (key, idx) pairs by key.
   subroutine sort_pairs(key, idx, n)
      integer, intent(inout) :: key(:), idx(:)
      integer, intent(in) :: n
      integer, allocatable :: k2(:), i2(:)
      integer :: width, lo, mid, hi, a, b, t
      if (n <= 1) return
      allocate (k2(n), i2(n))
      width = 1
      do while (width < n)
         lo = 1
         do while (lo <= n)
            mid = min(lo + width - 1, n)
            hi = min(lo + 2*width - 1, n)
            a = lo
            b = mid + 1
            t = lo
            do while (t <= hi)
               if (a <= mid .and. (b > hi .or. key(a) <= key(b))) then
                  k2(t) = key(a)
                  i2(t) = idx(a)
                  a = a + 1
               else
                  k2(t) = key(b)
                  i2(t) = idx(b)
                  b = b + 1
               end if
               t = t + 1
            end do
            lo = lo + 2*width
         end do
         key = k2
         idx = i2
         width = 2*width
      end do
      deallocate (k2, i2)
   end subroutine sort_pairs

end program check_image
