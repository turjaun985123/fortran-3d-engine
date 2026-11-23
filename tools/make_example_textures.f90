! make_example_textures.f90 -- deterministic generator for the
! Phase 4 example texture assets (examples/assets/).
!
! Usage: make_example_textures [output_dir]   (default
! "examples/assets").  No RNG anywhere: every texel is an
! analytic function of its coordinates, so re-running the tool
! reproduces the committed assets byte-for-byte.
!
! Outputs:
!   tiles-normal.ppm  64x64 binary PPM (P6): a tangent-space
!     normal map of a bevelled-tile surface with one rivet bump
!     per tile.  Height is analytic (bevel profile + Gaussian
!     rivets); normals come from its central differences.
!   fence-alpha.png   64x64 RGBA PNG (stored-deflate zlib, filter
!     0 rows; written by the small writer below): vertical fence
!     slats -- alpha 255 on the slats, 0 in the gaps -- over a
!     deterministic wood-tone RGB.  Used by examples/
!     alpha-masked.f3d as its base-colour + alpha texture.
program make_example_textures
    implicit none
    integer, parameter :: dp = kind(1.0d0)
    character(len=512) :: outdir
    integer :: narg

    narg = command_argument_count()
    outdir = 'examples/assets'
    if (narg >= 1) call get_command_argument(1, outdir)

    call write_normal_map(trim(outdir) // '/tiles-normal.ppm')
    call write_fence_png(trim(outdir) // '/fence-alpha.png')
    print '(A)', 'wrote tiles-normal.ppm and fence-alpha.png to ' &
        // trim(outdir)

contains

    ! Height of the tile surface at continuous texel coords
    ! (x, y in 0..64).  Tiles are 16 texels; the bevel rises over
    ! the outer 4 texels of each tile; a rivet (Gaussian bump,
    ! sigma 1.5) sits at each tile's (4, 4) inset corner.
    function tile_height(x, y) result(h)
        real(dp), intent(in) :: x, y
        real(dp) :: h, tx, ty, d, bevel, rx, ry
        tx = mod(x, 16.0_dp)
        ty = mod(y, 16.0_dp)
        d = min(tx, 16.0_dp - tx, ty, 16.0_dp - ty)
        bevel = sin(min(d / 4.0_dp, 1.0_dp) * 1.5707963267948966_dp)
        rx = tx - 4.0_dp
        ry = ty - 4.0_dp
        h = bevel + 0.6_dp * exp(-(rx * rx + ry * ry) &
                                 / (2.0_dp * 1.5_dp * 1.5_dp))
    end function tile_height

    subroutine write_normal_map(path)
        character(len=*), intent(in) :: path
        integer, parameter :: W = 64, H = 64
        integer :: unit, i, j, ios
        real(dp) :: gx, gy, inv_len, nx, ny, nz, strength
        character(len=1) :: byte
        strength = 2.0_dp
        open(newunit=unit, file=path, status='replace', &
             access='stream', form='unformatted', iostat=ios)
        if (ios /= 0) stop 'cannot open normal map output'
        write(unit) 'P6' // char(10) // '64 64' // char(10) &
            // '255' // char(10)
        do j = 0, H - 1
            do i = 0, W - 1
                ! Central differences (tile_height is periodic
                ! with the 64-texel image via the 16-texel tile
                ! mod, so the map tiles seamlessly).
                gx = (tile_height(real(i + 1, dp), real(j, dp)) &
                    - tile_height(real(i - 1, dp), real(j, dp))) &
                    * 0.5_dp * strength
                gy = (tile_height(real(i, dp), real(j + 1, dp)) &
                    - tile_height(real(i, dp), real(j - 1, dp))) &
                    * 0.5_dp * strength
                inv_len = 1.0_dp / sqrt(gx * gx + gy * gy + 1.0_dp)
                nx = -gx * inv_len
                ny = gy * inv_len   ! PPM row 0 is the top; v up
                nz = inv_len
                byte = char(nint((nx * 0.5_dp + 0.5_dp) * 255.0_dp))
                write(unit) byte
                byte = char(nint((ny * 0.5_dp + 0.5_dp) * 255.0_dp))
                write(unit) byte
                byte = char(nint((nz * 0.5_dp + 0.5_dp) * 255.0_dp))
                write(unit) byte
            end do
        end do
        close(unit)
    end subroutine write_normal_map

    ! ---- Minimal PNG writer: 8-bit RGBA, stored-deflate zlib. ----
    subroutine write_fence_png(path)
        character(len=*), intent(in) :: path
        integer, parameter :: W = 64, H = 64
        integer, parameter :: RAW = H * (1 + W * 4)
        integer, allocatable :: rawb(:), idatb(:)
        integer :: n_idat
        integer :: i, j, p, slat, shade
        integer :: r, g, b, a
        allocate(rawb(RAW), idatb(RAW + 32))

        ! Raw scanlines: filter byte 0, then RGBA per texel.
        ! Slats: 10 texels wood, 6 texels gap, period 16.
        p = 0
        do j = 0, H - 1
            p = p + 1
            rawb(p) = 0
            do i = 0, W - 1
                slat = mod(i, 16)
                if (slat < 10) then
                    a = 255
                    shade = 200 - 6 * slat + mod(j, 3) * 4
                    r = shade
                    g = shade * 3 / 5
                    b = shade / 4
                else
                    a = 0
                    r = 0
                    g = 0
                    b = 0
                end if
                rawb(p + 1) = r
                rawb(p + 2) = g
                rawb(p + 3) = b
                rawb(p + 4) = a
                p = p + 4
            end do
        end do

        call zlib_store(rawb, RAW, idatb, n_idat)

        block
            integer :: unit, ios
            integer :: ihdr(13)
            open(newunit=unit, file=path, status='replace', &
                 access='stream', form='unformatted', iostat=ios)
            if (ios /= 0) stop 'cannot open fence png output'
            ! PNG signature.
            call put_bytes(unit, [137, 80, 78, 71, 13, 10, 26, 10])
            ! IHDR: width, height, bit depth 8, colour type 6
            ! (RGBA), compression 0, filter 0, interlace 0.
            ihdr = 0
            call put_be32(ihdr, 1, W)
            call put_be32(ihdr, 5, H)
            ihdr(9) = 8
            ihdr(10) = 6
            call put_chunk(unit, 'IHDR', ihdr, 13)
            call put_chunk(unit, 'IDAT', idatb, n_idat)
            call put_chunk(unit, 'IEND', ihdr, 0)
            close(unit)
        end block
    end subroutine write_fence_png

    subroutine put_be32(buf, off, val)
        integer, intent(inout) :: buf(:)
        integer, intent(in) :: off, val
        buf(off) = iand(ishft(val, -24), 255)
        buf(off + 1) = iand(ishft(val, -16), 255)
        buf(off + 2) = iand(ishft(val, -8), 255)
        buf(off + 3) = iand(val, 255)
    end subroutine put_be32

    subroutine put_bytes(unit, bytes)
        integer, intent(in) :: unit
        integer, intent(in) :: bytes(:)
        integer :: k
        do k = 1, size(bytes)
            write(unit) char(bytes(k))
        end do
    end subroutine put_bytes

    subroutine put_chunk(unit, ctype, data, n)
        integer, intent(in) :: unit
        character(len=4), intent(in) :: ctype
        integer, intent(in) :: data(:), n
        integer :: crc, k
        integer :: lenb(4), crcb(4), typeb(4)
        call put_be32(lenb, 1, n)
        call put_bytes(unit, lenb)
        do k = 1, 4
            typeb(k) = ichar(ctype(k:k))
        end do
        call put_bytes(unit, typeb)
        if (n > 0) call put_bytes(unit, data(1:n))
        crc = crc32_init()
        do k = 1, 4
            crc = crc32_byte(crc, typeb(k))
        end do
        do k = 1, n
            crc = crc32_byte(crc, data(k))
        end do
        crc = ieor(crc, -1)
        call put_be32(crcb, 1, crc)
        call put_bytes(unit, crcb)
    end subroutine put_chunk

    function crc32_init() result(c)
        integer :: c
        c = -1  ! all-ones in two's complement int32
    end function crc32_init

    function crc32_byte(crc_in, byte) result(crc_out)
        integer, intent(in) :: crc_in, byte
        integer :: crc_out, k, c
        c = ieor(crc_in, iand(byte, 255))
        do k = 1, 8
            if (iand(c, 1) /= 0) then
                c = ieor(ishft(c, -1), -306674912)  ! 0xEDB88320
            else
                c = ishft(c, -1)
            end if
        end do
        crc_out = c
    end function crc32_byte

    ! zlib stream of stored (uncompressed) DEFLATE blocks.
    subroutine zlib_store(raw, n, out, n_out)
        integer, intent(in) :: raw(:), n
        integer, intent(out) :: out(:), n_out
        integer :: pos, off, blk, adler_a, adler_b, k
        out(1) = 120   ! 0x78: deflate, 32K window
        out(2) = 1     ! 0x01: stored-friendly FLEVEL
        pos = 2
        off = 0
        do while (.true.)
            blk = min(65535, n - off)
            pos = pos + 1
            if (off + blk >= n) then
                out(pos) = 1  ! BFINAL=1, BTYPE=00
            else
                out(pos) = 0
            end if
            out(pos + 1) = iand(blk, 255)
            out(pos + 2) = iand(ishft(blk, -8), 255)
            out(pos + 3) = iand(not(blk), 255)
            out(pos + 4) = iand(ishft(not(blk), -8), 255)
            pos = pos + 4
            do k = 1, blk
                out(pos + k) = raw(off + k)
            end do
            pos = pos + blk
            off = off + blk
            if (off >= n) exit
        end do
        adler_a = 1
        adler_b = 0
        do k = 1, n
            adler_a = mod(adler_a + raw(k), 65521)
            adler_b = mod(adler_b + adler_a, 65521)
        end do
        ! Adler32 is stored big-endian as (b << 16) | a.
        out(pos + 1) = iand(ishft(adler_b, -8), 255)
        out(pos + 2) = iand(adler_b, 255)
        out(pos + 3) = iand(ishft(adler_a, -8), 255)
        out(pos + 4) = iand(adler_a, 255)
        n_out = pos + 4
    end subroutine zlib_store

end program make_example_textures
