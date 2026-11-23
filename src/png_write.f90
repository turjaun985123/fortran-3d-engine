! png_write_3d -- dependency-free PNG encoder (Forge3D v2.0 P2).
!
! Writes a truecolor (color type 2), 8-bit, non-interlaced PNG from an
! integer RGB pixel array.  The IDAT payload is a zlib stream made of
! DEFLATE *stored* (uncompressed) blocks, so no compression library is
! needed: correctness over size.  CRC-32 (PNG polynomial 0xEDB88320,
! reflected) and Adler-32 are computed here in Fortran.
module png_write_3d
    use, intrinsic :: iso_fortran_env, only: int64
    implicit none
    private
    public :: png_save_file

    integer(int64), parameter :: CRC_POLY = 3988292384_int64   ! 0xEDB88320
    integer(int64), parameter :: CRC_MASK = 4294967295_int64   ! 0xFFFFFFFF
    integer(int64), parameter :: ADLER_MOD = 65521_int64

contains

    ! Advance a CRC-32 state (pre-complement convention: start from
    ! CRC_MASK, xor with CRC_MASK at the end) over raw bytes.
    function crc32_update(crc, bytes) result(out)
        integer(int64), intent(in) :: crc
        character(len=1), intent(in) :: bytes(:)
        integer(int64) :: out
        integer :: i, bit

        out = crc
        do i = 1, size(bytes)
            out = ieor(out, int(ichar(bytes(i)), int64))
            do bit = 1, 8
                if (iand(out, 1_int64) == 1_int64) then
                    out = ieor(ishft(out, -1), CRC_POLY)
                else
                    out = ishft(out, -1)
                end if
            end do
        end do
    end function crc32_update

    ! Four big-endian bytes of a 32-bit value, as characters.
    function be32(v) result(s)
        integer(int64), intent(in) :: v
        character(len=4) :: s
        s(1:1) = char(int(iand(ishft(v, -24), 255_int64)))
        s(2:2) = char(int(iand(ishft(v, -16), 255_int64)))
        s(3:3) = char(int(iand(ishft(v, -8), 255_int64)))
        s(4:4) = char(int(iand(v, 255_int64)))
    end function be32

    ! Write one PNG chunk: length, type, data, CRC(type+data).
    subroutine write_chunk(u, ctype, data)
        integer, intent(in) :: u
        character(len=4), intent(in) :: ctype
        character(len=1), intent(in) :: data(:)
        integer(int64) :: crc
        character(len=1) :: type_bytes(4)
        integer :: i

        do i = 1, 4
            type_bytes(i) = ctype(i:i)
        end do
        crc = crc32_update(CRC_MASK, type_bytes)
        crc = crc32_update(crc, data)
        crc = ieor(crc, CRC_MASK)

        write(u) be32(int(size(data), int64))
        write(u) ctype
        if (size(data) > 0) write(u) data
        write(u) be32(crc)
    end subroutine write_chunk

    ! Save pixels(1:3, x, y) (integers 0..255, same layout the PPM
    ! writer reads) as a PNG file at `filename`.
    subroutine png_save_file(filename, width, height, pixels)
        character(len=*), intent(in) :: filename
        integer, intent(in) :: width, height
        integer, intent(in) :: pixels(3, width, height)
        integer :: u, x, y, k, i
        integer(int64) :: raw_size, zsize, nblocks, blk, remaining, offset
        integer(int64) :: pos, adler_a, adler_b, adler
        character(len=1), allocatable :: raw(:), zbuf(:)
        character(len=1) :: ihdr(13), empty(0)
        character(len=8) :: signature
        character(len=4) :: tmp4

        ! Raw scanlines: filter byte 0, then RGB bytes per pixel.
        raw_size = int(height, int64) * (1_int64 + 3_int64 * int(width, int64))
        allocate(raw(raw_size))
        pos = 1
        do y = 1, height
            raw(pos) = char(0)
            pos = pos + 1
            do x = 1, width
                do k = 1, 3
                    raw(pos) = char(min(255, max(0, pixels(k, x, y))))
                    pos = pos + 1
                end do
            end do
        end do

        ! Adler-32 of the raw data.
        adler_a = 1_int64
        adler_b = 0_int64
        do i = 1, int(raw_size)
            adler_a = mod(adler_a + int(ichar(raw(i)), int64), ADLER_MOD)
            adler_b = mod(adler_b + adler_a, ADLER_MOD)
        end do
        adler = adler_b * 65536_int64 + adler_a

        ! zlib stream: header 0x78 0x01, stored blocks of <= 65535
        ! bytes (BFINAL on the last), Adler-32 big-endian trailer.
        nblocks = (raw_size + 65534_int64) / 65535_int64
        if (nblocks < 1_int64) nblocks = 1_int64
        zsize = 2_int64 + raw_size + 5_int64 * nblocks + 4_int64
        allocate(zbuf(zsize))
        zbuf(1) = char(120)  ! 0x78: deflate, 32K window
        zbuf(2) = char(1)    ! 0x01: FCHECK makes 0x7801 divisible by 31
        pos = 3
        offset = 1
        remaining = raw_size
        do while (remaining > 0_int64)
            blk = min(65535_int64, remaining)
            if (blk == remaining) then
                zbuf(pos) = char(1)  ! BFINAL=1, BTYPE=00 (stored)
            else
                zbuf(pos) = char(0)  ! BFINAL=0, BTYPE=00 (stored)
            end if
            pos = pos + 1
            ! LEN little-endian, then NLEN = one's complement of LEN.
            zbuf(pos) = char(int(iand(blk, 255_int64)))
            zbuf(pos + 1) = char(int(iand(ishft(blk, -8), 255_int64)))
            zbuf(pos + 2) = char(int(iand(65535_int64 - blk, 255_int64)))
            zbuf(pos + 3) = char(int(iand(ishft(65535_int64 - blk, -8), &
                                      255_int64)))
            pos = pos + 4
            zbuf(pos:pos + blk - 1) = raw(offset:offset + blk - 1)
            pos = pos + blk
            offset = offset + blk
            remaining = remaining - blk
        end do
        tmp4 = be32(adler)
        do i = 1, 4
            zbuf(pos + i - 1) = tmp4(i:i)
        end do

        ! IHDR: width, height (big-endian), bit depth 8, color type 2
        ! (truecolor RGB), compression 0, filter 0, interlace 0.
        tmp4 = be32(int(width, int64))
        do i = 1, 4
            ihdr(i) = tmp4(i:i)
        end do
        tmp4 = be32(int(height, int64))
        do i = 1, 4
            ihdr(4 + i) = tmp4(i:i)
        end do
        ihdr(9) = char(8)
        ihdr(10) = char(2)
        ihdr(11) = char(0)
        ihdr(12) = char(0)
        ihdr(13) = char(0)

        signature = char(137) // 'PNG' // char(13) // char(10) // &
                    char(26) // char(10)

        open(newunit=u, file=filename, access='stream', &
             form='unformatted', status='replace', action='write')
        write(u) signature
        call write_chunk(u, 'IHDR', ihdr)
        call write_chunk(u, 'IDAT', zbuf)
        call write_chunk(u, 'IEND', empty)
        close(u)

        deallocate(raw, zbuf)
    end subroutine png_save_file

end module png_write_3d
