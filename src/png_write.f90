! png_write_3d -- dependency-free PNG encoder (Forge3D v2.0 P2,
! v3.0 Phase 8: real DEFLATE compression).
!
! Writes a truecolor (color type 2), 8-bit, non-interlaced PNG from an
! integer RGB pixel array.  CRC-32 (PNG polynomial 0xEDB88320,
! reflected) and Adler-32 are computed here in Fortran.
!
! IDAT / zlib encoder (Phase 8)
! ------------------------------
! The IDAT payload is a zlib stream whose DEFLATE payload is produced
! by a real compressor, not stored blocks:
!
!   * LZ77 matching over the filtered scanline byte stream produced
!     by png_save_file (filter byte + RGB bytes per scanline; the
!     filter choice itself is unchanged by this encoder).  A hash
!     chain over 3-byte sequences searches the previous 32768 bytes
!     (the DEFLATE window) for matches of length 3..258.  The chain
!     walk is capped (MAX_CHAIN), so the search cost per position is
!     bounded.  A candidate match is emitted only when its coded size
!     (length code + length extra bits + distance code + distance
!     extra bits) is strictly smaller than coding the same bytes as
!     literals; that rule is also what makes the output bound below
!     provable.
!   * The matches/literals are coded as ONE fixed-Huffman DEFLATE
!     block (BTYPE=01, RFC 1951 section 3.2.6) through an LSB-first
!     bit writer; Huffman codes themselves are emitted MSB-first by
!     bit-reversing each code before it enters the bit writer.
!
! Why fixed Huffman and not dynamic Huffman: a dynamic block must
! first build optimal code lengths, transmit them (HLIT/HDIST/HCLEN
! plus the code-length code), and carry the tables in code and in
! state.  For this engine's renders the fixed tables recover most of
! the available gain at a fraction of the code size and with no
! per-block table that could be malformed; the complexity is not
! justified on this hot output path.
!
! Stored fallback rule: the fixed-Huffman stream is compared against
! the exact size of the stored-block stream for the same bytes, and
! the smaller one is written.  Compression therefore NEVER grows the
! file relative to the old stored-only writer: incompressible data
! falls back to stored blocks (BFINAL/BTYPE framing unchanged).
!
! Output bound: because every emitted match is strictly cheaper than
! the literals it replaces, a compressed payload is never larger
! than the literal-only fixed-Huffman stream: 3 header bits +
! 9 bits/byte worst case (literals 144..255 use 9-bit codes) +
! 7 bits end-of-block, plus one flush byte.  The payload buffer is
! sized by exactly that bound, so no output allocation is unbounded
! and the bit writer additionally range-checks every byte it emits
! (on overflow the caller falls back to stored blocks).
module png_write_3d
    use, intrinsic :: iso_fortran_env, only: int64
    implicit none
    private
    public :: png_save_file

    integer(int64), parameter :: CRC_POLY = 3988292384_int64   ! 0xEDB88320
    integer(int64), parameter :: CRC_MASK = 4294967295_int64   ! 0xFFFFFFFF
    integer(int64), parameter :: ADLER_MOD = 65521_int64

    ! DEFLATE / LZ77 constants (RFC 1951).
    integer, parameter :: LZ_WINDOW = 32768
    integer, parameter :: LZ_MIN_MATCH = 3
    integer, parameter :: LZ_MAX_MATCH = 258
    integer, parameter :: LZ_MAX_CHAIN = 128
    integer, parameter :: LZ_HASH_BITS = 15
    integer, parameter :: LZ_HASH_SIZE = 32768  ! 2**LZ_HASH_BITS

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

    ! Reverse the low `nbits` bits of `code`.  DEFLATE packs values
    ! LSB-first but Huffman codes MSB-first, so a fixed-Huffman code
    ! must be bit-reversed before it goes into the bit writer.
    function bit_reverse(code, nbits) result(r)
        integer, intent(in) :: code, nbits
        integer :: r, i
        r = 0
        do i = 1, nbits
            r = ior(ishft(r, 1), iand(ishft(code, -(i - 1)), 1))
        end do
    end function bit_reverse

    ! Fixed-Huffman code (value and bit length) for a literal/length
    ! symbol 0..287 (RFC 1951 section 3.2.6).
    subroutine fixed_litlen_code(sym, code, nbits)
        integer, intent(in) :: sym
        integer, intent(out) :: code, nbits
        if (sym < 144) then
            code = 48 + sym              ! 00110000 .. 10111111
            nbits = 8
        else if (sym < 256) then
            code = 400 + (sym - 144)     ! 110010000 .. 111111111
            nbits = 9
        else if (sym < 280) then
            code = sym - 256             ! 0000000 .. 0010111
            nbits = 7
        else
            code = 192 + (sym - 280)     ! 11000000 .. 11000111
            nbits = 8
        end if
    end subroutine fixed_litlen_code

    ! Map a match length (3..258) to its length symbol, extra-bit
    ! count and extra-bit value (RFC 1951 section 3.2.5).
    subroutine length_info(length, sym, ebits, evalue)
        integer, intent(in) :: length
        integer, intent(out) :: sym, ebits, evalue
        integer, parameter :: base(29) = [ &
            3, 4, 5, 6, 7, 8, 9, 10, 11, 13, 15, 17, 19, 23, 27, 31, &
            35, 43, 51, 59, 67, 83, 99, 115, 131, 163, 195, 227, 258]
        integer, parameter :: extra(29) = [ &
            0, 0, 0, 0, 0, 0, 0, 0, 1, 1, 1, 1, 2, 2, 2, 2, &
            3, 3, 3, 3, 4, 4, 4, 4, 5, 5, 5, 5, 0]
        integer :: i, chosen

        chosen = 1
        do i = 1, 29
            if (base(i) <= length) chosen = i
        end do
        ! Length 258 belongs to symbol 285 (index 29), never to 284.
        if (length == 258) chosen = 29
        sym = 256 + chosen
        ebits = extra(chosen)
        evalue = length - base(chosen)
    end subroutine length_info

    ! Map a match distance (1..32768) to its distance symbol,
    ! extra-bit count and extra-bit value (RFC 1951 section 3.2.5).
    subroutine distance_info(dist, sym, ebits, evalue)
        integer, intent(in) :: dist
        integer, intent(out) :: sym, ebits, evalue
        integer, parameter :: base(30) = [ &
            1, 2, 3, 4, 5, 7, 9, 13, 17, 25, 33, 49, 65, 97, 129, &
            193, 257, 385, 513, 769, 1025, 1537, 2049, 3073, 4097, &
            6145, 8193, 12289, 16385, 24577]
        integer, parameter :: extra(30) = [ &
            0, 0, 0, 0, 1, 1, 2, 2, 3, 3, 4, 4, 5, 5, 6, &
            6, 7, 7, 8, 8, 9, 9, 10, 10, 11, 11, 12, 12, 13, 13]
        integer :: i, chosen

        chosen = 1
        do i = 1, 30
            if (base(i) <= dist) chosen = i
        end do
        sym = chosen - 1
        ebits = extra(chosen)
        evalue = dist - base(chosen)
    end subroutine distance_info

    ! Hash of the 3 bytes starting at position p of ub (0-based hash,
    ! LZ_HASH_SIZE buckets).  Caller guarantees p+2 <= size(ub).
    function lz_hash(ub, p) result(h)
        integer, intent(in) :: ub(:)
        integer, intent(in) :: p
        integer :: h
        h = ieor(ishft(ub(p), 10), ieor(ishft(ub(p + 1), 5), ub(p + 2)))
        h = iand(h, LZ_HASH_SIZE - 1)
    end function lz_hash

    ! Compress raw(1:n) into payload as a single fixed-Huffman
    ! DEFLATE block.  payload must be sized by the caller's proven
    ! upper bound (see the module header); ok is .false. if that
    ! bound was ever exceeded, in which case payload_len is 0 and
    ! the caller must fall back to stored blocks.
    subroutine deflate_fixed(raw, n, payload, payload_len, ok)
        character(len=1), intent(in) :: raw(:)
        integer, intent(in) :: n
        character(len=1), intent(out) :: payload(:)
        integer(int64), intent(out) :: payload_len
        logical, intent(out) :: ok
        integer, allocatable :: ub(:), head(:), prev(:)
        integer(int64) :: bitbuf, outpos
        integer :: bitcnt, cur, cand, chain, l, p
        integer :: best_len, best_dist, lit_bits, match_bits
        integer :: sym, ebits, evalue, code, nbits
        logical :: overflow, use_match

        ok = .true.
        payload_len = 0_int64
        overflow = .false.
        if (n < 0) then
            ok = .false.
            return
        end if

        allocate(ub(max(1, n)), head(LZ_HASH_SIZE), &
                 prev(max(1, n)))
        do p = 1, n
            ub(p) = ichar(raw(p))
        end do
        head = 0
        prev = 0

        bitbuf = 0_int64
        bitcnt = 0
        outpos = 1_int64

        ! Block header: BFINAL=1, BTYPE=01 (fixed Huffman).
        call put_bits(1_int64, 1)
        call put_bits(1_int64, 2)

        cur = 1
        do while (cur <= n)
            if (overflow) exit
            best_len = 0
            best_dist = 0
            if (cur + LZ_MIN_MATCH - 1 <= n) then
                ! Walk the hash chain for the 3 bytes at cur,
                ! newest candidate first; distances only grow
                ! along the chain, so leaving the window ends it.
                cand = head(lz_hash(ub, cur) + 1)
                chain = 0
                do
                    if (cand <= 0) exit
                    if (chain >= LZ_MAX_CHAIN) exit
                    if (cur - cand > LZ_WINDOW) exit
                    l = 0
                    do
                        if (l >= LZ_MAX_MATCH) exit
                        if (cur + l > n) exit
                        if (ub(cand + l) /= ub(cur + l)) exit
                        l = l + 1
                    end do
                    if (l >= LZ_MIN_MATCH) then
                        if (l > best_len) then
                            best_len = l
                            best_dist = cur - cand
                            if (l >= LZ_MAX_MATCH) chain = LZ_MAX_CHAIN
                        end if
                    end if
                    cand = prev(cand)
                    chain = chain + 1
                end do
            end if

            use_match = .false.
            if (best_len >= LZ_MIN_MATCH) then
                ! Emit the match only if it is strictly cheaper
                ! than the literals it replaces (see header: this
                ! is what bounds the whole stream by the
                ! literal-only size).
                lit_bits = 0
                do p = cur, cur + best_len - 1
                    if (ub(p) < 144) then
                        lit_bits = lit_bits + 8
                    else
                        lit_bits = lit_bits + 9
                    end if
                end do
                call length_info(best_len, sym, ebits, evalue)
                call fixed_litlen_code(sym, code, nbits)
                match_bits = nbits + ebits
                call distance_info(best_dist, sym, ebits, evalue)
                match_bits = match_bits + 5 + ebits
                if (match_bits < lit_bits) use_match = .true.
            end if

            if (use_match) then
                call length_info(best_len, sym, ebits, evalue)
                call fixed_litlen_code(sym, code, nbits)
                call put_huffman(code, nbits)
                if (ebits > 0) call put_bits(int(evalue, int64), ebits)
                call distance_info(best_dist, sym, ebits, evalue)
                ! Distance codes are 5-bit fixed-Huffman codes
                ! whose value is the symbol itself.
                call put_huffman(sym, 5)
                if (ebits > 0) call put_bits(int(evalue, int64), ebits)
                do p = cur, cur + best_len - 1
                    call insert_pos(p)
                end do
                cur = cur + best_len
            else
                call fixed_litlen_code(ub(cur), code, nbits)
                call put_huffman(code, nbits)
                call insert_pos(cur)
                cur = cur + 1
            end if
        end do

        if (overflow) then
            ok = .false.
            deallocate(ub, head, prev)
            return
        end if

        ! End-of-block symbol 256, then flush the partial byte
        ! (zero padded, as DEFLATE requires).
        call fixed_litlen_code(256, code, nbits)
        call put_huffman(code, nbits)
        if (overflow) then
            ok = .false.
            deallocate(ub, head, prev)
            return
        end if
        if (bitcnt > 0) then
            if (outpos > int(size(payload), int64)) then
                ok = .false.
                deallocate(ub, head, prev)
                return
            end if
            payload(outpos) = char(int(iand(bitbuf, 255_int64)))
            outpos = outpos + 1
        end if

        payload_len = outpos - 1
        deallocate(ub, head, prev)

    contains

        ! Append the low nbits of val to the stream, LSB-first.
        subroutine put_bits(val, nbits_in)
            integer(int64), intent(in) :: val
            integer, intent(in) :: nbits_in
            if (overflow) return
            bitbuf = ior(bitbuf, ishft(val, bitcnt))
            bitcnt = bitcnt + nbits_in
            do while (bitcnt >= 8)
                if (outpos > int(size(payload), int64)) then
                    overflow = .true.
                    return
                end if
                payload(outpos) = char(int(iand(bitbuf, 255_int64)))
                outpos = outpos + 1
                bitbuf = ishft(bitbuf, -8)
                bitcnt = bitcnt - 8
            end do
        end subroutine put_bits

        ! Append a Huffman code, MSB-first (via bit reversal).
        subroutine put_huffman(code_in, nbits_in)
            integer, intent(in) :: code_in, nbits_in
            call put_bits(int(bit_reverse(code_in, nbits_in), int64), &
                          nbits_in)
        end subroutine put_huffman

        ! Insert position p into the hash chain (no-op when fewer
        ! than LZ_MIN_MATCH bytes remain at p).
        subroutine insert_pos(p_in)
            integer, intent(in) :: p_in
            integer :: h
            if (p_in + LZ_MIN_MATCH - 1 <= n) then
                h = lz_hash(ub, p_in) + 1
                prev(p_in) = head(h)
                head(h) = p_in
            end if
        end subroutine insert_pos

    end subroutine deflate_fixed

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
        integer(int64) :: stored_size, cbound, payload_len, zpos
        character(len=1), allocatable :: raw(:), zbuf(:), cbuf(:)
        character(len=1) :: ihdr(13), empty(0)
        character(len=8) :: signature
        character(len=4) :: tmp4
        logical :: deflate_ok, use_deflate

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

        ! Exact size of the stored-block zlib stream for these
        ! bytes: header 2, blocks of <= 65535 bytes with a 5-byte
        ! header each, Adler-32 trailer 4.
        nblocks = (raw_size + 65534_int64) / 65535_int64
        if (nblocks < 1_int64) nblocks = 1_int64
        stored_size = 2_int64 + raw_size + 5_int64 * nblocks + 4_int64

        ! Compress the filtered byte stream.  The payload buffer is
        ! sized by the proven literal-only upper bound from the
        ! module header (3 + 9*raw_size + 7 bits, rounded up, plus
        ! slack for the final flush byte).
        cbound = (9_int64 * raw_size + 24_int64) / 8_int64 + 8_int64
        allocate(cbuf(cbound))
        payload_len = 0_int64
        deflate_ok = .false.
        if (raw_size <= int(huge(1), int64)) then
            call deflate_fixed(raw, int(raw_size), cbuf, payload_len, &
                               deflate_ok)
        end if

        ! Choose per stream: compressed only when the whole zlib
        ! stream is strictly smaller than the stored stream.
        use_deflate = .false.
        if (deflate_ok) then
            if (2_int64 + payload_len + 4_int64 < stored_size) &
                use_deflate = .true.
        end if

        if (use_deflate) then
            zsize = 2_int64 + payload_len + 4_int64
            allocate(zbuf(zsize))
            zbuf(1) = char(120)  ! 0x78: deflate, 32K window
            zbuf(2) = char(156)  ! 0x9C: FCHECK makes 0x789C % 31 == 0
            if (payload_len > 0_int64) &
                zbuf(3:2 + payload_len) = cbuf(1:payload_len)
            tmp4 = be32(adler)
            zpos = 3_int64 + payload_len
            do i = 1, 4
                zbuf(zpos + i - 1) = tmp4(i:i)
            end do
        else
            ! Stored fallback: header 0x78 0x01, stored blocks of
            ! <= 65535 bytes (BFINAL on the last), Adler-32 trailer.
            zsize = stored_size
            allocate(zbuf(zsize))
            zbuf(1) = char(120)  ! 0x78: deflate, 32K window
            zbuf(2) = char(1)    ! 0x01: FCHECK makes 0x7801 % 31 == 0
            pos = 3
            offset = 1
            remaining = raw_size
            if (remaining == 0_int64) then
                zbuf(pos) = char(1)  ! BFINAL=1, BTYPE=00, LEN=0
                zbuf(pos + 1) = char(0)
                zbuf(pos + 2) = char(0)
                zbuf(pos + 3) = char(255)
                zbuf(pos + 4) = char(255)
                pos = pos + 5
            end if
            do while (remaining > 0_int64)
                blk = min(65535_int64, remaining)
                if (blk == remaining) then
                    zbuf(pos) = char(1)  ! BFINAL=1, BTYPE=00 (stored)
                else
                    zbuf(pos) = char(0)  ! BFINAL=0, BTYPE=00 (stored)
                end if
                pos = pos + 1
                ! LEN little-endian, then NLEN = one's complement.
                zbuf(pos) = char(int(iand(blk, 255_int64)))
                zbuf(pos + 1) = char(int(iand(ishft(blk, -8), 255_int64)))
                zbuf(pos + 2) = char(int(iand(65535_int64 - blk, &
                                              255_int64)))
                zbuf(pos + 3) = char(int(iand(ishft(65535_int64 - blk, &
                                                    -8), 255_int64)))
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
        end if
        deallocate(cbuf)

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
