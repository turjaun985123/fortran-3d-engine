! texture.f90 -- texture images (PPM) and procedural primitive UVs.
!
! Module texture_3d, Wave A seat B51.  Owns ONLY texture storage,
! PPM loading, nearest-neighbour sampling and the frozen per-primitive
! UV mapping (contract P14).  It has no dependency on mesh_3d: the
! Triangle type carries no uv field, so UVs are computed on demand
! from a primitive name, a LOCAL vertex and the primitive's full
! extents by prim_uv().
!
! ---------------------------------------------------------------------
! Storage / sampling conventions
! ---------------------------------------------------------------------
! TextureImage%pixels is (3, w, h): channel (1=R,2=G,3=B), column
! (1..w, left to right) and row (1..h, TOP row first, exactly as the
! rows appear in the PPM file).  Values are integers in 0..255.
!
! texture_sample() uses NEAREST neighbour and REPEAT wrapping on both
! axes: the wrapped coordinate is u - floor(u) (likewise v), so any
! real u, v is valid.  v = 1 is the TOP of the image and v = 0 the
! bottom (row = floor((1 - wrapped_v) * h) + 1, clamped), while
! u = 0 is the left edge and u = 1 the right edge.  Sampling a
! texture that is not loaded returns the documented debug colour
! MAGENTA (255, 0, 255), which is deliberately impossible to miss
! in a render.
!
! ---------------------------------------------------------------------
! Frozen UV contract (P14) -- orientation test-card contract
! ---------------------------------------------------------------------
! prim_uv(prim, v, ext) takes a LOCAL vertex v (centred at the
! primitive's origin, as produced by the mesh_3d builders) and the
! FULL extents ext = (sx, sy, sz) (e.g. a cube of size 2 has
! ext = (2,2,2); a sphere of radius r has ext = (2r,2r,2r); a plane
! of width w and depth d has ext = (w, 0, d)).  It returns
! uv = (u, v) in 0..1 unless noted otherwise.
!
!   cube / box / pyramid -- per-face planar projection.  The face is
!     chosen by the dominant axis: the largest of |v%x|/(sx/2),
!     |v%y|/(sy/2), |v%z|/(sz/2).  The other two axes are mapped
!     linearly from -extent/2..+extent/2 to 0..1, oriented so the
!     texture reads correctly (not mirrored) when that face is
!     viewed from outside:
!       +Z face: u from +x, v from +y.  *** TEST-CARD ANCHOR: on a
!         front-facing (+Z) cube face, u increases with +x and v
!         increases with +y (v = 1 at the top, v = 0 at the bottom,
!         u = 0 at the left, u = 1 at the right). ***
!       -Z face: u from -x, v from +y (unmirrored from behind).
!       +X face: u from -z, v from +y.
!       -X face: u from +z, v from +y.
!       +Y face: u from +x, v from -z.
!       -Y face: u from +x, v from +z.
!     pyramid uses exactly this cube rule (its slanted faces take
!     whichever axis dominates at the vertex).
!   sphere -- spherical coordinates:
!       u = atan2(z, x) / (2*pi) + 0.5
!       v = acos(y / r) / pi,  r = |v|
!     so v = 0 at the +Y (top) pole, v = 0.5 at the equator and
!     v = 1 at the -Y (bottom) pole.  The degenerate vertex r = 0
!     returns uv = (0.5, 0.5).
!   cylinder / cone -- cylindrical coordinates around Y:
!       u = atan2(z, x) / (2*pi) + 0.5,  v = y / sy + 0.5
!     so v = 0 at the base (-sy/2) and v = 1 at the top (+sy/2).
!     (For a cone the same rule applies along its height.)
!   plane -- planar: u = x / sx + 0.5, v = z / sz + 0.5, so the
!     (-sx/2, -sz/2) corner is (0,0) and (+sx/2, +sz/2) is (1,1).
!   torus -- u is the angle around the main ring (around Y):
!       u = atan2(z, x) / (2*pi) + 0.5
!     and v is the angle around the tube:
!       v = atan2(y, radial - R) / (2*pi) + 0.5
!     where R = sx/2 - sy/2 is the major radius recovered from the
!     extents (tube radius = sy/2) and radial = sqrt(x^2 + z^2).
!     v = 0.5 on the outer equator of the tube, 0.75 at its top.
!   Any other primitive name returns uv = (0, 0).
!
! All returned planar/cylindrical components are clamped to 0..1.
!
! ---------------------------------------------------------------------
! Phase 4 extensions (v3 texture core) -- ADDITIVE ONLY
! ---------------------------------------------------------------------
! The legacy surface above (pixels(3,w,h), texture_load_ppm,
! texture_sample nearest, prim_uv) is frozen per ADR-1 and unchanged.
! Added in Phase 4:
!   * TextureImage gains alpha/has_alpha, srgb/filter/wrap settings
!     and a mip chain (levels of MipLevel, real32 LINEAR rgba).
!   * PNG decoding with an in-module DEFLATE/inflate implementation
!     (stored + fixed-Huffman + dynamic-Huffman blocks) and full PNG
!     unfiltering (None/Sub/Up/Average/Paeth).  Colour types 0 (grey),
!     2 (RGB), 3 (palette via PLTE), 4 (grey+alpha), 6 (RGBA);
!     bit depth 8, plus 16-bit samples reduced to the high byte.
!     Chunk CRCs are IGNORED (documented choice): chunk lengths and
!     the zlib FCHECK are validated structurally instead.
!     LIMIT: Adam7-interlaced PNGs are REJECTED (ok = .false.);
!     palette bit depths below 8 and other bit depths (1/2/4) are
!     also rejected.
!   * texture_load() dispatches on magic bytes (PNG signature, or
!     'P3'/'P6' to the PPM loader).
!   * texture_build_mips() builds the mip chain in LINEAR space
!     (sRGB-decoded when tex%srgb; alpha never sRGB-decoded).
!   * texture_sample_f() samples real32 LINEAR rgba honouring
!     tex%filter (0 nearest, 1 bilinear, 2 trilinear) and tex%wrap
!     (0 repeat, 1 clamp, 2 mirror), with the same v convention as
!     texture_sample (v = 1 is the TOP row).  u/v/lod are real(dp).
module texture_3d
    use, intrinsic :: iso_fortran_env, only: int8, real32
    use math_3d, only: dp, vec3, PI
    implicit none
    private
    public :: TextureImage, MipLevel, texture_load_ppm, texture_free, &
              texture_sample, prim_uv, &
              png_decode, texture_load_png, texture_load, &
              texture_build_mips, texture_sample_f

    type :: MipLevel
        integer :: w = 0
        integer :: h = 0
        real(real32), allocatable :: rgba(:, :, :)  ! (4, w, h) LINEAR
    end type MipLevel

    ! Private helpers for the DEFLATE decoder (Phase 4).
    type :: BitReader
        integer(int8), allocatable :: data(:)
        integer :: bytepos = 1   ! 1-based next byte
        integer :: bitpos = 0    ! 0..7, LSB first
    end type BitReader

    type :: HuffTable
        integer :: counts(0:15) = 0
        integer, allocatable :: symbols(:)
        integer :: maxbits = 0
    end type HuffTable

    type :: TextureImage
        integer :: w = 0
        integer :: h = 0
        integer, allocatable :: pixels(:, :, :)  ! (3, w, h), 0..255
        logical :: loaded = .false.
        ! --- Phase 4 additive fields ---
        integer, allocatable :: alpha(:, :)     ! (w, h), 0..255
        logical :: has_alpha = .false.
        logical :: srgb = .true.
        integer :: filter = 2        ! 0 nearest, 1 bilinear, 2 trilinear
        integer :: wrap = 0          ! 0 repeat, 1 clamp, 2 mirror
        type(MipLevel), allocatable :: levels(:)
    end type TextureImage

contains

    subroutine texture_free(tex)
        type(TextureImage), intent(inout) :: tex
        integer :: i
        if (allocated(tex%pixels)) deallocate(tex%pixels)
        if (allocated(tex%alpha)) deallocate(tex%alpha)
        if (allocated(tex%levels)) then
            do i = 1, size(tex%levels)
                if (allocated(tex%levels(i)%rgba)) &
                    deallocate(tex%levels(i)%rgba)
            end do
            deallocate(tex%levels)
        end if
        tex%w = 0
        tex%h = 0
        tex%loaded = .false.
        tex%has_alpha = .false.
        tex%srgb = .true.
        tex%filter = 2
        tex%wrap = 0
    end subroutine texture_free

    ! Load a PPM image: P3 (ASCII) or P6 (binary), maxval 255 in the
    ! canonical case; any other positive maxval is scaled to 0..255.
    ! On any failure (missing file, bad magic, bad dimensions,
    ! truncated data, unsupported maxval for P6) ok = .false., tex is
    ! left unloaded, and the subroutine returns without error.
    subroutine texture_load_ppm(path, tex, ok)
        character(len=*), intent(in) :: path
        type(TextureImage), intent(out) :: tex
        logical, intent(out) :: ok
        integer :: unit, ios, fsize, i
        integer(int8), allocatable :: bytes(:)
        integer :: pos, w, h, maxval, magic
        logical :: good

        ok = .false.
        tex%w = 0; tex%h = 0; tex%loaded = .false.

        open(newunit=unit, file=path, status='old', action='read', &
             access='stream', form='unformatted', iostat=ios)
        if (ios /= 0) return
        inquire(unit=unit, size=fsize)
        if (fsize <= 0) then
            close(unit)
            return
        end if
        allocate(bytes(fsize))
        read(unit, iostat=ios) (bytes(i), i = 1, fsize)
        close(unit)
        if (ios /= 0) then
            deallocate(bytes)
            return
        end if
        ! Bytes stay signed (int8); header bytes are ASCII (< 128) and
        ! read_p6_data converts raster bytes to unsigned 0..255.

        pos = 1
        call parse_header(bytes, pos, magic, w, h, maxval, good)
        if (.not. good) then
            deallocate(bytes)
            return
        end if
        if (w <= 0 .or. h <= 0 .or. w > 16384 .or. h > 16384) then
            deallocate(bytes)
            return
        end if

        allocate(tex%pixels(3, w, h))
        if (magic == 3) then
            call read_p3_data(bytes, pos, w, h, maxval, tex%pixels, good)
        else
            ! P6 samples are single bytes, so maxval must fit a byte.
            if (maxval > 255) good = .false.
            if (good) call read_p6_data(bytes, pos, w, h, maxval, tex%pixels, good)
        end if
        deallocate(bytes)
        if (.not. good) then
            call texture_free(tex)
            return
        end if
        tex%w = w
        tex%h = h
        tex%loaded = .true.
        ok = .true.
    end subroutine texture_load_ppm

    ! Parse "P3"/"P6", width, height, maxval.  On entry pos=1; on
    ! success pos is just past the maxval token (for P6 the caller
    ! skips the single whitespace delimiter via read_p6_data).
    subroutine parse_header(bytes, pos, magic, w, h, maxval, good)
        integer(int8), intent(in) :: bytes(:)
        integer, intent(inout) :: pos
        integer, intent(out) :: magic, w, h, maxval
        logical, intent(out) :: good
        character(len=32) :: tok

        good = .false.
        magic = 0; w = 0; h = 0; maxval = 0
        call next_token(bytes, pos, tok, good)
        if (.not. good) return
        if (tok == 'P3') then
            magic = 3
        else if (tok == 'P6') then
            magic = 6
        else
            good = .false.
            return
        end if
        call next_int(bytes, pos, w, good)
        if (.not. good) return
        call next_int(bytes, pos, h, good)
        if (.not. good) return
        call next_int(bytes, pos, maxval, good)
        if (.not. good) return
        if (maxval < 1) then
            good = .false.
            return
        end if
        good = .true.
    end subroutine parse_header

    ! Advance pos past whitespace and #-to-end-of-line comments.
    subroutine skip_ws_comments(bytes, pos)
        integer(int8), intent(in) :: bytes(:)
        integer, intent(inout) :: pos
        integer :: n
        n = size(bytes)
        do while (pos <= n)
            if (bytes(pos) == 35) then  ! '#'
                do while (pos <= n .and. bytes(pos) /= 10)
                    pos = pos + 1
                end do
            else if (bytes(pos) == 32 .or. bytes(pos) == 9 .or. &
                     bytes(pos) == 10 .or. bytes(pos) == 13) then
                pos = pos + 1
            else
                exit
            end if
        end do
    end subroutine skip_ws_comments

    subroutine next_token(bytes, pos, tok, good)
        integer(int8), intent(in) :: bytes(:)
        integer, intent(inout) :: pos
        character(len=*), intent(out) :: tok
        logical, intent(out) :: good
        integer :: n, start, len_tok
        n = size(bytes)
        call skip_ws_comments(bytes, pos)
        tok = ''
        good = .false.
        if (pos > n) return
        start = pos
        do while (pos <= n)
            if (bytes(pos) == 32 .or. bytes(pos) == 9 .or. &
                bytes(pos) == 10 .or. bytes(pos) == 13 .or. &
                bytes(pos) == 35) exit
            pos = pos + 1
        end do
        len_tok = pos - start
        if (len_tok <= 0 .or. len_tok > len(tok)) return
        block
            integer :: k
            do k = 1, len_tok
                tok(k:k) = char(bytes(start + k - 1))
            end do
        end block
        good = .true.
    end subroutine next_token

    subroutine next_int(bytes, pos, val, good)
        integer(int8), intent(in) :: bytes(:)
        integer, intent(inout) :: pos
        integer, intent(out) :: val
        logical, intent(out) :: good
        character(len=32) :: tok
        integer :: ios
        call next_token(bytes, pos, tok, good)
        val = 0
        if (.not. good) return
        read(tok, *, iostat=ios) val
        if (ios /= 0) good = .false.
    end subroutine next_int

    subroutine read_p3_data(bytes, pos, w, h, maxval, pixels, good)
        integer(int8), intent(in) :: bytes(:)
        integer, intent(inout) :: pos
        integer, intent(in) :: w, h, maxval
        integer, intent(out) :: pixels(3, w, h)
        logical, intent(out) :: good
        integer :: row, col, ch, val
        good = .true.
        do row = 1, h
            do col = 1, w
                do ch = 1, 3
                    call next_int(bytes, pos, val, good)
                    if (.not. good) return
                    if (val < 0 .or. val > maxval) then
                        good = .false.
                        return
                    end if
                    pixels(ch, col, row) = scale_val(val, maxval)
                end do
            end do
        end do
    end subroutine read_p3_data

    subroutine read_p6_data(bytes, pos, w, h, maxval, pixels, good)
        integer(int8), intent(in) :: bytes(:)
        integer, intent(inout) :: pos
        integer, intent(in) :: w, h, maxval
        integer, intent(out) :: pixels(3, w, h)
        logical, intent(out) :: good
        integer :: row, col, ch, idx, bval
        good = .false.
        ! Exactly one whitespace byte separates header from raster;
        ! tolerate a CRLF pair as that single delimiter.
        if (pos > size(bytes)) return
        if (bytes(pos) == 13 .and. pos + 1 <= size(bytes)) then
            if (bytes(pos + 1) == 10) pos = pos + 1
        end if
        pos = pos + 1
        if (pos + w * h * 3 - 1 > size(bytes)) return
        idx = pos
        do row = 1, h
            do col = 1, w
                do ch = 1, 3
                    bval = int(bytes(idx))
                    if (bval < 0) bval = bval + 256
                    pixels(ch, col, row) = scale_val(bval, maxval)
                    idx = idx + 1
                end do
            end do
        end do
        good = .true.
    end subroutine read_p6_data

    pure function scale_val(val, maxval) result(scaled)
        integer, intent(in) :: val, maxval
        integer :: scaled
        if (maxval == 255) then
            scaled = val
        else
            scaled = (val * 255 + maxval / 2) / maxval
        end if
    end function scale_val

    pure function texture_sample(tex, u, v) result(rgb)
        type(TextureImage), intent(in) :: tex
        real(dp), intent(in) :: u, v
        integer :: rgb(3)
        real(dp) :: wu, wv
        integer :: col, row

        rgb = [255, 0, 255]  ! magenta debug colour
        if (.not. tex%loaded) return
        if (.not. allocated(tex%pixels)) return
        if (tex%w <= 0 .or. tex%h <= 0) return

        wu = u - floor(u)
        wv = v - floor(v)
        col = int(wu * real(tex%w, dp)) + 1
        row = int((1.0_dp - wv) * real(tex%h, dp)) + 1
        if (col < 1) col = 1
        if (col > tex%w) col = tex%w
        if (row < 1) row = 1
        if (row > tex%h) row = tex%h
        rgb = tex%pixels(:, col, row)
    end function texture_sample

    pure function prim_uv(prim, v, ext) result(uv)
        character(len=*), intent(in) :: prim
        type(vec3), intent(in) :: v
        real(dp), intent(in) :: ext(3)
        real(dp) :: uv(2)
        character(len=32) :: name

        name = trim(prim)
        select case (name)
        case ('cube', 'box', 'pyramid')
            uv = box_uv(v, ext)
        case ('sphere')
            uv = sphere_uv(v)
        case ('cylinder', 'cone')
            uv = cyl_uv(v, ext)
        case ('plane')
            uv(1) = clamp01(axis_map(v%x, ext(1)))
            uv(2) = clamp01(axis_map(v%z, ext(3)))
        case ('torus')
            uv = torus_uv(v, ext)
        case default
            uv = [0.0_dp, 0.0_dp]
        end select
    end function prim_uv

    ! Map a coordinate in -extent/2..+extent/2 to 0..1.
    pure function axis_map(coord, extent) result(t)
        real(dp), intent(in) :: coord, extent
        real(dp) :: t
        if (extent > 0.0_dp) then
            t = coord / extent + 0.5_dp
        else
            t = 0.5_dp
        end if
    end function axis_map

    pure function clamp01(x) result(c)
        real(dp), intent(in) :: x
        real(dp) :: c
        c = min(1.0_dp, max(0.0_dp, x))
    end function clamp01

    pure function box_uv(v, ext) result(uv)
        type(vec3), intent(in) :: v
        real(dp), intent(in) :: ext(3)
        real(dp) :: uv(2)
        real(dp) :: ax, ay, az

        ax = 0.0_dp; ay = 0.0_dp; az = 0.0_dp
        if (ext(1) > 0.0_dp) ax = abs(v%x) / (0.5_dp * ext(1))
        if (ext(2) > 0.0_dp) ay = abs(v%y) / (0.5_dp * ext(2))
        if (ext(3) > 0.0_dp) az = abs(v%z) / (0.5_dp * ext(3))

        if (az >= ax .and. az >= ay) then
            ! +/- Z face: v from +y; u from +x on +Z, from -x on -Z.
            if (v%z >= 0.0_dp) then
                uv(1) = axis_map(v%x, ext(1))
            else
                uv(1) = 1.0_dp - axis_map(v%x, ext(1))
            end if
            uv(2) = axis_map(v%y, ext(2))
        else if (ax >= ay) then
            ! +/- X face: v from +y; u from -z on +X, from +z on -X.
            if (v%x >= 0.0_dp) then
                uv(1) = 1.0_dp - axis_map(v%z, ext(3))
            else
                uv(1) = axis_map(v%z, ext(3))
            end if
            uv(2) = axis_map(v%y, ext(2))
        else
            ! +/- Y face: u from +x; v from -z on +Y, from +z on -Y.
            uv(1) = axis_map(v%x, ext(1))
            if (v%y >= 0.0_dp) then
                uv(2) = 1.0_dp - axis_map(v%z, ext(3))
            else
                uv(2) = axis_map(v%z, ext(3))
            end if
        end if
        uv(1) = clamp01(uv(1))
        uv(2) = clamp01(uv(2))
    end function box_uv

    pure function sphere_uv(v) result(uv)
        type(vec3), intent(in) :: v
        real(dp) :: uv(2)
        real(dp) :: r, c
        r = sqrt(v%x * v%x + v%y * v%y + v%z * v%z)
        if (r <= 0.0_dp) then
            uv = [0.5_dp, 0.5_dp]
            return
        end if
        uv(1) = atan2(v%z, v%x) / (2.0_dp * PI) + 0.5_dp
        c = min(1.0_dp, max(-1.0_dp, v%y / r))
        uv(2) = acos(c) / PI
    end function sphere_uv

    pure function cyl_uv(v, ext) result(uv)
        type(vec3), intent(in) :: v
        real(dp), intent(in) :: ext(3)
        real(dp) :: uv(2)
        uv(1) = atan2(v%z, v%x) / (2.0_dp * PI) + 0.5_dp
        uv(2) = clamp01(axis_map(v%y, ext(2)))
    end function cyl_uv

    pure function torus_uv(v, ext) result(uv)
        type(vec3), intent(in) :: v
        real(dp), intent(in) :: ext(3)
        real(dp) :: uv(2)
        real(dp) :: radial, big_r, dir_x, dir_z, radial_local

        uv(1) = atan2(v%z, v%x) / (2.0_dp * PI) + 0.5_dp
        radial = sqrt(v%x * v%x + v%z * v%z)
        big_r = 0.5_dp * ext(1) - 0.5_dp * ext(2)
        if (big_r < 0.0_dp) big_r = 0.0_dp
        if (radial > 1.0e-12_dp) then
            dir_x = v%x / radial
            dir_z = v%z / radial
            radial_local = (v%x - big_r * dir_x) * dir_x + &
                           (v%z - big_r * dir_z) * dir_z
        else
            radial_local = -big_r
        end if
        uv(2) = atan2(v%y, radial_local) / (2.0_dp * PI) + 0.5_dp
    end function torus_uv

    ! =================================================================
    ! Phase 4: file loading dispatcher + PNG decoder (own inflate)
    ! =================================================================

    ! Read a whole file into a byte array.  ok=.false. on any failure.
    subroutine read_file_bytes(path, bytes, ok)
        character(len=*), intent(in) :: path
        integer(int8), allocatable, intent(out) :: bytes(:)
        logical, intent(out) :: ok
        integer :: unit, ios, fsize, i
        ok = .false.
        open(newunit=unit, file=path, status='old', action='read', &
             access='stream', form='unformatted', iostat=ios)
        if (ios /= 0) return
        inquire(unit=unit, size=fsize)
        if (fsize <= 0) then
            close(unit)
            return
        end if
        allocate(bytes(fsize))
        read(unit, iostat=ios) (bytes(i), i = 1, fsize)
        close(unit)
        if (ios /= 0) then
            deallocate(bytes)
            return
        end if
        ok = .true.
    end subroutine read_file_bytes

    pure function ubyte(b) result(v)
        integer(int8), intent(in) :: b
        integer :: v
        v = int(b)
        if (v < 0) v = v + 256
    end function ubyte

    ! Dispatch on magic bytes: PNG signature -> PNG decoder,
    ! 'P3'/'P6' -> the (frozen) PPM loader, anything else fails.
    subroutine texture_load(path, tex, ok)
        character(len=*), intent(in) :: path
        type(TextureImage), intent(out) :: tex
        logical, intent(out) :: ok
        integer(int8), allocatable :: head(:)
        integer :: unit, ios
        ok = .false.
        open(newunit=unit, file=path, status='old', action='read', &
             access='stream', form='unformatted', iostat=ios)
        if (ios /= 0) return
        allocate(head(8))
        head = 0_int8
        read(unit, iostat=ios) head
        close(unit)
        if (ios /= 0) then
            deallocate(head)
            return
        end if
        if (ubyte(head(1)) == 137 .and. ubyte(head(2)) == 80 .and. &
            ubyte(head(3)) == 78 .and. ubyte(head(4)) == 71 .and. &
            ubyte(head(5)) == 13 .and. ubyte(head(6)) == 10 .and. &
            ubyte(head(7)) == 26 .and. ubyte(head(8)) == 10) then
            call texture_load_png(path, tex, ok)
        else if (head(1) == iachar('P') .and. &
                 (head(2) == iachar('3') .or. head(2) == iachar('6'))) then
            call texture_load_ppm(path, tex, ok)
        else
            tex%w = 0; tex%h = 0; tex%loaded = .false.
            ok = .false.
        end if
        deallocate(head)
    end subroutine texture_load

    subroutine texture_load_png(path, tex, ok)
        character(len=*), intent(in) :: path
        type(TextureImage), intent(out) :: tex
        logical, intent(out) :: ok
        integer(int8), allocatable :: bytes(:)
        logical :: rok
        ok = .false.
        call read_file_bytes(path, bytes, rok)
        if (.not. rok) then
            tex%w = 0; tex%h = 0; tex%loaded = .false.
            return
        end if
        call png_decode(bytes, tex, ok)
        deallocate(bytes)
    end subroutine texture_load_png

    pure function be32(bytes, pos) result(v)
        integer(int8), intent(in) :: bytes(:)
        integer, intent(in) :: pos
        integer :: v
        v = ubyte(bytes(pos)) * 16777216 + ubyte(bytes(pos + 1)) * 65536 &
            + ubyte(bytes(pos + 2)) * 256 + ubyte(bytes(pos + 3))
    end function be32

    ! Decode a complete PNG file held in memory.  See the module
    ! header for supported features and the Adam7 limit.  On failure
    ! ok=.false. and tex is left unloaded.
    subroutine png_decode(bytes, tex, ok)
        integer(int8), intent(in) :: bytes(:)
        type(TextureImage), intent(out) :: tex
        logical, intent(out) :: ok
        integer :: pos, n, clen, w, h, bitdepth, ctype, interlace
        integer :: channels, bps, stride, i
        integer(int8), allocatable :: plte(:), idat(:), raw(:), recon(:)
        logical :: have_ihdr, have_plte, good
        character(len=4) :: ctype_str

        ok = .false.
        tex%w = 0; tex%h = 0; tex%loaded = .false.
        n = size(bytes)
        if (n < 8) return
        if (ubyte(bytes(1)) /= 137 .or. ubyte(bytes(2)) /= 80 .or. &
            ubyte(bytes(3)) /= 78 .or. ubyte(bytes(4)) /= 71 .or. &
            ubyte(bytes(5)) /= 13 .or. ubyte(bytes(6)) /= 10 .or. &
            ubyte(bytes(7)) /= 26 .or. ubyte(bytes(8)) /= 10) return

        w = 0; h = 0; bitdepth = 0; ctype = -1; interlace = 0
        have_ihdr = .false.; have_plte = .false.
        allocate(plte(0), idat(0))
        pos = 9
        do while (pos + 7 <= n)
            clen = be32(bytes, pos)
            if (clen < 0 .or. pos + 11 + clen > n) exit
            do i = 1, 4
                ctype_str(i:i) = char(ubyte(bytes(pos + 3 + i)))
            end do
            select case (ctype_str)
            case ('IHDR')
                if (clen < 13) exit
                w = be32(bytes, pos + 8)
                h = be32(bytes, pos + 12)
                bitdepth = ubyte(bytes(pos + 16))
                ctype = ubyte(bytes(pos + 17))
                if (ubyte(bytes(pos + 18)) /= 0) exit  ! compression
                if (ubyte(bytes(pos + 19)) /= 0) exit  ! filter method
                interlace = ubyte(bytes(pos + 20))
                have_ihdr = .true.
            case ('PLTE')
                deallocate(plte)
                allocate(plte(clen))
                if (clen > 0) plte = bytes(pos + 8:pos + 7 + clen)
                have_plte = .true.
            case ('IDAT')
                block
                    integer(int8), allocatable :: tmp(:)
                    allocate(tmp(size(idat) + clen))
                    if (size(idat) > 0) tmp(1:size(idat)) = idat
                    if (clen > 0) tmp(size(idat) + 1:) = &
                        bytes(pos + 8:pos + 7 + clen)
                    call move_alloc(tmp, idat)
                end block
            case ('IEND')
                exit
            case default
                ! Ancillary/unknown chunks skipped (CRC ignored).
            end select
            pos = pos + 12 + clen
        end do

        if (.not. have_ihdr) then
            deallocate(plte, idat); return
        end if
        if (w <= 0 .or. h <= 0 .or. w > 16384 .or. h > 16384) then
            deallocate(plte, idat); return
        end if
        if (interlace /= 0) then  ! Adam7 unsupported (documented limit)
            deallocate(plte, idat); return
        end if
        if (bitdepth /= 8 .and. bitdepth /= 16) then
            deallocate(plte, idat); return
        end if
        select case (ctype)
        case (0); channels = 1
        case (2); channels = 3
        case (3); channels = 1
            if (.not. have_plte .or. bitdepth /= 8) then
                deallocate(plte, idat); return
            end if
        case (4); channels = 2
        case (6); channels = 4
        case default
            deallocate(plte, idat); return
        end select
        if (size(idat) < 2) then
            deallocate(plte, idat); return
        end if
        bps = bitdepth / 8
        stride = w * channels * bps
        call inflate_zlib(idat, h * (stride + 1), raw, good)
        if (.not. good) then
            deallocate(plte, idat)
            if (allocated(raw)) deallocate(raw)
            return
        end if
        if (size(raw) < h * (stride + 1)) then
            deallocate(plte, idat, raw); return
        end if
        allocate(recon(h * stride))
        call png_unfilter(raw, h, channels * bps, stride, recon, good)
        deallocate(raw)
        if (.not. good) then
            deallocate(plte, idat, recon); return
        end if
        call png_to_tex(recon, w, h, ctype, bps, plte, tex, good)
        deallocate(plte, idat, recon)
        if (.not. good) then
            call texture_free(tex)
            return
        end if
        tex%loaded = .true.
        ok = .true.
    end subroutine png_decode

    ! Convert reconstructed scanlines into pixels/alpha.
    subroutine png_to_tex(recon, w, h, ctype, bps, plte, tex, good)
        integer(int8), intent(in) :: recon(:), plte(:)
        integer, intent(in) :: w, h, ctype, bps
        type(TextureImage), intent(inout) :: tex
        logical, intent(out) :: good
        integer :: row, col, base, idx, g, a
        good = .false.
        allocate(tex%pixels(3, w, h))
        allocate(tex%alpha(w, h))
        tex%alpha = 255
        tex%has_alpha = (ctype == 4 .or. ctype == 6)
        do row = 1, h
            do col = 1, w
                select case (ctype)
                case (0)  ! grey
                    base = ((row - 1) * w + (col - 1)) * bps
                    g = ubyte(recon(base + 1))
                    tex%pixels(:, col, row) = g
                case (2)  ! RGB
                    base = ((row - 1) * w + (col - 1)) * 3 * bps
                    tex%pixels(1, col, row) = ubyte(recon(base + 1))
                    tex%pixels(2, col, row) = ubyte(recon(base + 1 + bps))
                    tex%pixels(3, col, row) = ubyte(recon(base + 1 + 2 * bps))
                case (3)  ! palette (bitdepth 8 only, checked earlier)
                    base = (row - 1) * w + (col - 1)
                    idx = ubyte(recon(base + 1))
                    if (idx * 3 + 3 > size(plte)) then
                        call texture_free(tex)
                        return
                    end if
                    tex%pixels(1, col, row) = ubyte(plte(idx * 3 + 1))
                    tex%pixels(2, col, row) = ubyte(plte(idx * 3 + 2))
                    tex%pixels(3, col, row) = ubyte(plte(idx * 3 + 3))
                case (4)  ! grey + alpha
                    base = ((row - 1) * w + (col - 1)) * 2 * bps
                    g = ubyte(recon(base + 1))
                    a = ubyte(recon(base + 1 + bps))
                    tex%pixels(:, col, row) = g
                    tex%alpha(col, row) = a
                case (6)  ! RGBA
                    base = ((row - 1) * w + (col - 1)) * 4 * bps
                    tex%pixels(1, col, row) = ubyte(recon(base + 1))
                    tex%pixels(2, col, row) = ubyte(recon(base + 1 + bps))
                    tex%pixels(3, col, row) = ubyte(recon(base + 1 + 2 * bps))
                    tex%alpha(col, row) = ubyte(recon(base + 1 + 3 * bps))
                end select
            end do
        end do
        tex%w = w
        tex%h = h
        good = .true.
    end subroutine png_to_tex

    ! Reverse PNG scanline filters into recon (row-major, no filter
    ! bytes).  bpp = filter byte distance (bytes per pixel, min 1).
    subroutine png_unfilter(raw, h, bpp, stride, recon, good)
        integer(int8), intent(in) :: raw(:)
        integer, intent(in) :: h, bpp, stride
        integer(int8), intent(out) :: recon(:)
        logical, intent(out) :: good
        integer :: row, i, ftype, a, b, c, p, pa, pb, pc, pred, rp, up
        good = .false.
        do row = 1, h
            rp = (row - 1) * (stride + 1) + 1  ! filter byte position
            ftype = ubyte(raw(rp))
            if (ftype > 4) return
            do i = 1, stride
                a = 0; b = 0; c = 0
                if (i > bpp) a = ubyte(recon((row - 1) * stride + i - bpp))
                if (row > 1) b = ubyte(recon((row - 2) * stride + i))
                if (row > 1 .and. i > bpp) &
                    c = ubyte(recon((row - 2) * stride + i - bpp))
                select case (ftype)
                case (0); pred = 0
                case (1); pred = a
                case (2); pred = b
                case (3); pred = (a + b) / 2
                case (4)
                    p = a + b - c
                    pa = abs(p - a); pb = abs(p - b); pc = abs(p - c)
                    if (pa <= pb .and. pa <= pc) then
                        pred = a
                    else if (pb <= pc) then
                        pred = b
                    else
                        pred = c
                    end if
                end select
                up = ubyte(raw(rp + i)) + pred
                recon((row - 1) * stride + i) = int(mod(up, 256), int8)
            end do
        end do
        good = .true.
    end subroutine png_unfilter
    ! =================================================================
    ! DEFLATE / inflate (RFC 1951) + zlib wrapper (RFC 1950)
    ! =================================================================

    subroutine br_getbits(br, nbits, val, ok)
        type(BitReader), intent(inout) :: br
        integer, intent(in) :: nbits
        integer, intent(out) :: val
        logical, intent(inout) :: ok
        integer :: i, bit
        val = 0
        if (.not. ok) return
        do i = 0, nbits - 1
            if (br%bytepos > size(br%data)) then
                ok = .false.
                return
            end if
            bit = iand(ishft(ubyte(br%data(br%bytepos)), -br%bitpos), 1)
            val = val + ishft(bit, i)
            br%bitpos = br%bitpos + 1
            if (br%bitpos == 8) then
                br%bitpos = 0
                br%bytepos = br%bytepos + 1
            end if
        end do
    end subroutine br_getbits

    subroutine huff_build(lengths, table, ok)
        integer, intent(in) :: lengths(0:)
        type(HuffTable), intent(out) :: table
        logical, intent(out) :: ok
        integer :: offs(0:16), i, len, nsym
        ok = .false.
        table%counts = 0
        table%maxbits = 0
        do i = 0, size(lengths) - 1
            len = lengths(i)
            if (len < 0 .or. len > 15) return
            table%counts(len) = table%counts(len) + 1
            if (len > table%maxbits) table%maxbits = len
        end do
        table%counts(0) = 0
        nsym = sum(table%counts)
        if (nsym == 0) return
        allocate(table%symbols(nsym))
        offs(1) = 0
        do len = 1, 15
            offs(len + 1) = offs(len) + table%counts(len)
        end do
        do i = 0, size(lengths) - 1
            len = lengths(i)
            if (len > 0) then
                offs(len) = offs(len) + 1
                table%symbols(offs(len)) = i
            end if
        end do
        ok = .true.
    end subroutine huff_build

    subroutine huff_decode(br, table, sym, ok)
        type(BitReader), intent(inout) :: br
        type(HuffTable), intent(in) :: table
        integer, intent(out) :: sym
        logical, intent(inout) :: ok
        integer :: code, first, index, len, bit
        sym = -1
        if (.not. ok) return
        code = 0; first = 0; index = 0
        do len = 1, table%maxbits
            call br_getbits(br, 1, bit, ok)
            if (.not. ok) return
            code = code + bit
            if (code - table%counts(len) < first) then
                sym = table%symbols(index + (code - first) + 1)
                return
            end if
            index = index + table%counts(len)
            first = (first + table%counts(len)) * 2
            code = code * 2
        end do
        ok = .false.
    end subroutine huff_decode

    subroutine out_append(out, outlen, byte)
        integer(int8), allocatable, intent(inout) :: out(:)
        integer, intent(inout) :: outlen
        integer, intent(in) :: byte
        integer(int8), allocatable :: tmp(:)
        if (outlen >= size(out)) then
            allocate(tmp(max(1024, size(out) * 2)))
            if (size(out) > 0) tmp(1:size(out)) = out
            call move_alloc(tmp, out)
        end if
        outlen = outlen + 1
        out(outlen) = int(mod(byte, 256), int8)
    end subroutine out_append

    ! Inflate one compressed block set (the whole DEFLATE stream).
    subroutine inflate_blocks(br, out, outlen, ok)
        type(BitReader), intent(inout) :: br
        integer(int8), allocatable, intent(inout) :: out(:)
        integer, intent(inout) :: outlen
        logical, intent(out) :: ok
        integer :: bfinal, btype, v, i
        integer :: lit_lengths(0:287), dist_lengths(0:31)
        type(HuffTable) :: lit_tab, dist_tab
        logical :: lok
        integer, parameter :: len_base(29) = [ &
            3, 4, 5, 6, 7, 8, 9, 10, 11, 13, 15, 17, 19, 23, 27, 31, &
            35, 43, 51, 59, 67, 83, 99, 115, 131, 163, 195, 227, 258]
        integer, parameter :: len_extra(29) = [ &
            0, 0, 0, 0, 0, 0, 0, 0, 1, 1, 1, 1, 2, 2, 2, 2, &
            3, 3, 3, 3, 4, 4, 4, 4, 5, 5, 5, 5, 0]
        integer, parameter :: dist_base(30) = [ &
            1, 2, 3, 4, 5, 7, 9, 13, 17, 25, 33, 49, 65, 97, 129, 193, &
            257, 385, 513, 769, 1025, 1537, 2049, 3073, 4097, 6145, &
            8193, 12289, 16385, 24577]
        integer, parameter :: dist_extra(30) = [ &
            0, 0, 0, 0, 1, 1, 2, 2, 3, 3, 4, 4, 5, 5, 6, 6, &
            7, 7, 8, 8, 9, 9, 10, 10, 11, 11, 12, 12, 13, 13]

        ok = .false.
        do
            lok = .true.
            call br_getbits(br, 1, bfinal, lok)
            if (.not. lok) return
            call br_getbits(br, 2, btype, lok)
            if (.not. lok) return
            select case (btype)
            case (0)  ! stored
                if (br%bitpos /= 0) then
                    br%bitpos = 0
                    br%bytepos = br%bytepos + 1
                end if
                if (br%bytepos + 3 > size(br%data)) return
                v = ubyte(br%data(br%bytepos)) + &
                    256 * ubyte(br%data(br%bytepos + 1))
                i = ubyte(br%data(br%bytepos + 2)) + &
                    256 * ubyte(br%data(br%bytepos + 3))
                if (i /= 65535 - v) return  ! NLEN must complement LEN
                br%bytepos = br%bytepos + 4
                if (br%bytepos + v - 1 > size(br%data)) return
                do i = 1, v
                    call out_append(out, outlen, &
                                    ubyte(br%data(br%bytepos)))
                    br%bytepos = br%bytepos + 1
                end do
            case (1)  ! fixed Huffman
                lit_lengths(0:143) = 8
                lit_lengths(144:255) = 9
                lit_lengths(256:279) = 7
                lit_lengths(280:287) = 8
                dist_lengths(0:29) = 5
                dist_lengths(30:31) = 0
                call huff_build(lit_lengths, lit_tab, lok)
                if (.not. lok) return
                call huff_build(dist_lengths(0:29), dist_tab, lok)
                if (.not. lok) return
                call inflate_compressed(br, lit_tab, dist_tab, out, &
                     outlen, len_base, len_extra, dist_base, &
                     dist_extra, lok)
                if (allocated(lit_tab%symbols)) deallocate(lit_tab%symbols)
                if (allocated(dist_tab%symbols)) deallocate(dist_tab%symbols)
                if (.not. lok) return
            case (2)  ! dynamic Huffman
                call read_dynamic_tables(br, lit_lengths, dist_lengths, lok)
                if (.not. lok) return
                call huff_build(lit_lengths, lit_tab, lok)
                if (.not. lok) return
                block
                    integer :: nd
                    nd = 0
                    do i = 0, 31
                        if (dist_lengths(i) > 0) nd = i
                    end do
                    call huff_build(dist_lengths(0:nd), dist_tab, lok)
                end block
                if (.not. lok) then
                    if (allocated(lit_tab%symbols)) &
                        deallocate(lit_tab%symbols)
                    return
                end if
                call inflate_compressed(br, lit_tab, dist_tab, out, &
                     outlen, len_base, len_extra, dist_base, &
                     dist_extra, lok)
                if (allocated(lit_tab%symbols)) deallocate(lit_tab%symbols)
                if (allocated(dist_tab%symbols)) deallocate(dist_tab%symbols)
                if (.not. lok) return
            case default
                return
            end select
            if (bfinal == 1) exit
        end do
        ok = .true.
    end subroutine inflate_blocks

    subroutine read_dynamic_tables(br, lit_lengths, dist_lengths, ok)
        type(BitReader), intent(inout) :: br
        integer, intent(out) :: lit_lengths(0:287), dist_lengths(0:31)
        logical, intent(out) :: ok
        integer, parameter :: order(19) = [16, 17, 18, 0, 8, 7, 9, 6, &
                                           10, 5, 11, 4, 12, 3, 13, 2, &
                                           14, 1, 15]
        integer :: hlit, hdist, hclen, i, v, sym, rep, prev, total
        integer :: cl_lengths(0:18), all_lengths(0:319)
        type(HuffTable) :: cl_tab
        logical :: lok
        ok = .false.
        lok = .true.
        lit_lengths = 0; dist_lengths = 0; cl_lengths = 0
        call br_getbits(br, 5, hlit, lok); if (.not. lok) return
        hlit = hlit + 257
        call br_getbits(br, 5, hdist, lok); if (.not. lok) return
        hdist = hdist + 1
        call br_getbits(br, 4, hclen, lok); if (.not. lok) return
        hclen = hclen + 4
        do i = 1, hclen
            call br_getbits(br, 3, v, lok); if (.not. lok) return
            cl_lengths(order(i)) = v
        end do
        call huff_build(cl_lengths, cl_tab, lok)
        if (.not. lok) return
        total = hlit + hdist
        all_lengths = 0
        i = 0
        do while (i < total)
            call huff_decode(br, cl_tab, sym, lok)
            if (.not. lok) exit
            select case (sym)
            case (0:15)
                all_lengths(i) = sym
                i = i + 1
            case (16)
                if (i == 0) then
                    lok = .false.
                    exit
                end if
                prev = all_lengths(i - 1)
                call br_getbits(br, 2, v, lok); if (.not. lok) exit
                rep = v + 3
                if (i + rep > total) then
                    lok = .false.
                    exit
                end if
                do v = 1, rep
                    all_lengths(i) = prev
                    i = i + 1
                end do
            case (17)
                call br_getbits(br, 3, v, lok); if (.not. lok) exit
                rep = v + 3
                if (i + rep > total) then
                    lok = .false.
                    exit
                end if
                i = i + rep
            case (18)
                call br_getbits(br, 7, v, lok); if (.not. lok) exit
                rep = v + 11
                if (i + rep > total) then
                    lok = .false.
                    exit
                end if
                i = i + rep
            case default
                lok = .false.
                exit
            end select
        end do
        if (allocated(cl_tab%symbols)) deallocate(cl_tab%symbols)
        if (.not. lok) return
        lit_lengths(0:hlit - 1) = all_lengths(0:hlit - 1)
        dist_lengths(0:hdist - 1) = all_lengths(hlit:hlit + hdist - 1)
        ok = .true.
    end subroutine read_dynamic_tables

    subroutine inflate_compressed(br, lit_tab, dist_tab, out, outlen, &
                                  len_base, len_extra, dist_base, &
                                  dist_extra, ok)
        type(BitReader), intent(inout) :: br
        type(HuffTable), intent(in) :: lit_tab, dist_tab
        integer(int8), allocatable, intent(inout) :: out(:)
        integer, intent(inout) :: outlen
        integer, intent(in) :: len_base(29), len_extra(29)
        integer, intent(in) :: dist_base(30), dist_extra(30)
        logical, intent(out) :: ok
        integer :: sym, dsym, v, length, dist, i
        logical :: lok
        ok = .false.
        lok = .true.
        do
            call huff_decode(br, lit_tab, sym, lok)
            if (.not. lok) return
            if (sym < 256) then
                call out_append(out, outlen, sym)
            else if (sym == 256) then
                exit
            else if (sym <= 285) then
                call br_getbits(br, len_extra(sym - 256), v, lok)
                if (.not. lok) return
                length = len_base(sym - 256) + v
                call huff_decode(br, dist_tab, dsym, lok)
                if (.not. lok) return
                if (dsym < 0 .or. dsym > 29) return
                call br_getbits(br, dist_extra(dsym + 1), v, lok)
                if (.not. lok) return
                dist = dist_base(dsym + 1) + v
                if (dist > outlen) return
                do i = 1, length
                    call out_append(out, outlen, &
                                    ubyte(out(outlen - dist + 1)))
                end do
            else
                return
            end if
        end do
        ok = .true.
    end subroutine inflate_compressed

    ! zlib stream: 2 header bytes (FCHECK validated), DEFLATE data,
    ! Adler-32 trailer (ignored).  expect_hint sizes the output guess.
    subroutine inflate_zlib(zdata, expect_hint, out, ok)
        integer(int8), intent(in) :: zdata(:)
        integer, intent(in) :: expect_hint
        integer(int8), allocatable, intent(out) :: out(:)
        logical, intent(out) :: ok
        type(BitReader) :: br
        integer :: cmf, flg, outlen
        ok = .false.
        if (size(zdata) < 6) return
        cmf = ubyte(zdata(1)); flg = ubyte(zdata(2))
        if (mod(cmf, 16) /= 8) return            ! CM = deflate
        if (mod(cmf * 256 + flg, 31) /= 0) return  ! FCHECK
        if (iand(flg, 32) /= 0) return           ! preset dictionary
        allocate(br%data(size(zdata) - 2))
        br%data = zdata(3:)
        br%bytepos = 1; br%bitpos = 0
        allocate(out(max(1024, expect_hint)))
        outlen = 0
        call inflate_blocks(br, out, outlen, ok)
        deallocate(br%data)
        if (.not. ok) then
            deallocate(out)
            return
        end if
        block
            integer(int8), allocatable :: tmp(:)
            allocate(tmp(outlen))
            if (outlen > 0) tmp = out(1:outlen)
            call move_alloc(tmp, out)
        end block
        ok = .true.
    end subroutine inflate_zlib
    ! =================================================================
    ! Phase 4: sRGB decode, mipmaps, filtered sampling
    ! =================================================================

    pure function srgb_byte_to_linear(b, srgb) result(x)
        integer, intent(in) :: b
        logical, intent(in) :: srgb
        real(real32) :: x
        real(dp) :: s
        s = real(b, dp) / 255.0_dp
        if (srgb) then
            if (s <= 0.04045_dp) then
                s = s / 12.92_dp
            else
                s = ((s + 0.055_dp) / 1.055_dp) ** 2.4_dp
            end if
        end if
        x = real(s, real32)
    end function srgb_byte_to_linear

    pure function texel_linear(tex, col, row) result(rgba)
        type(TextureImage), intent(in) :: tex
        integer, intent(in) :: col, row
        real(real32) :: rgba(4)
        integer :: ch
        do ch = 1, 3
            rgba(ch) = srgb_byte_to_linear(tex%pixels(ch, col, row), &
                                           tex%srgb)
        end do
        if (allocated(tex%alpha)) then
            rgba(4) = real(tex%alpha(col, row), real32) / 255.0_real32
        else
            rgba(4) = 1.0_real32
        end if
    end function texel_linear

    ! Build the mip chain from pixels/alpha.  Level 0 is the image
    ! itself (converted to LINEAR real32); each next level is the 2x2
    ! box mean of the previous (edge-aware for odd sizes) down to 1x1.
    ! Idempotent; a no-op on an unloaded texture.
    subroutine texture_build_mips(tex)
        type(TextureImage), intent(inout) :: tex
        integer :: i, nlev, w, h, nw, nh, x, y, sx, sy, cnt
        integer :: sx0, sx1, sy0, sy1
        real(real32) :: acc(4)
        if (.not. tex%loaded .or. .not. allocated(tex%pixels)) return
        if (tex%w <= 0 .or. tex%h <= 0) return
        if (allocated(tex%levels)) then
            do i = 1, size(tex%levels)
                if (allocated(tex%levels(i)%rgba)) &
                    deallocate(tex%levels(i)%rgba)
            end do
            deallocate(tex%levels)
        end if
        nlev = 1
        w = tex%w; h = tex%h
        do while (w > 1 .or. h > 1)
            w = max(1, (w + 1) / 2)
            h = max(1, (h + 1) / 2)
            nlev = nlev + 1
        end do
        allocate(tex%levels(nlev))
        allocate(tex%levels(1)%rgba(4, tex%w, tex%h))
        tex%levels(1)%w = tex%w
        tex%levels(1)%h = tex%h
        do y = 1, tex%h
            do x = 1, tex%w
                tex%levels(1)%rgba(:, x, y) = texel_linear(tex, x, y)
            end do
        end do
        do i = 2, nlev
            w = tex%levels(i - 1)%w
            h = tex%levels(i - 1)%h
            nw = max(1, (w + 1) / 2)
            nh = max(1, (h + 1) / 2)
            tex%levels(i)%w = nw
            tex%levels(i)%h = nh
            allocate(tex%levels(i)%rgba(4, nw, nh))
            do y = 1, nh
                sy0 = 2 * (y - 1) + 1
                sy1 = min(sy0 + 1, h)
                do x = 1, nw
                    sx0 = 2 * (x - 1) + 1
                    sx1 = min(sx0 + 1, w)
                    acc = 0.0_real32
                    cnt = 0
                    do sy = sy0, sy1
                        do sx = sx0, sx1
                            acc = acc + tex%levels(i - 1)%rgba(:, sx, sy)
                            cnt = cnt + 1
                        end do
                    end do
                    tex%levels(i)%rgba(:, x, y) = acc / real(cnt, real32)
                end do
            end do
        end do
    end subroutine texture_build_mips

    pure function wrap_coord(t, wrap) result(w)
        real(dp), intent(in) :: t
        integer, intent(in) :: wrap
        real(dp) :: w
        select case (wrap)
        case (1)  ! clamp
            w = min(1.0_dp, max(0.0_dp, t))
        case (2)  ! mirror
            w = t - 2.0_dp * floor(t / 2.0_dp)
            if (w > 1.0_dp) w = 2.0_dp - w
        case default  ! repeat
            w = t - floor(t)
        end select
    end function wrap_coord

    pure function wrap_index(i, n, wrap) result(j)
        integer, intent(in) :: i, n, wrap
        integer :: j
        select case (wrap)
        case (1)  ! clamp
            j = min(n - 1, max(0, i))
        case (2)  ! mirror
            j = mod(i, 2 * n)
            if (j < 0) j = j + 2 * n
            if (j >= n) j = 2 * n - 1 - j
        case default  ! repeat
            j = mod(i, n)
            if (j < 0) j = j + n
        end select
    end function wrap_index

    ! Fetch one texel (0-based col/row) of a level as LINEAR rgba.
    ! lev = 0 is the base level; when no mip chain exists the base
    ! level reads pixels/alpha directly.
    pure function level_texel(tex, lev, col, row) result(rgba)
        type(TextureImage), intent(in) :: tex
        integer, intent(in) :: lev, col, row
        real(real32) :: rgba(4)
        logical :: use_level
        use_level = .false.
        if (allocated(tex%levels)) then
            if (lev >= 0 .and. lev < size(tex%levels)) use_level = .true.
        end if
        if (use_level) then
            rgba = tex%levels(lev + 1)%rgba(:, col + 1, row + 1)
        else
            rgba = texel_linear(tex, col + 1, row + 1)
        end if
    end function level_texel

    pure subroutine level_dims(tex, lev, lw, lh, ok_dims)
        type(TextureImage), intent(in) :: tex
        integer, intent(in) :: lev
        integer, intent(out) :: lw, lh
        logical, intent(out) :: ok_dims
        logical :: use_level
        ok_dims = .true.
        use_level = .false.
        if (allocated(tex%levels)) then
            if (lev >= 0 .and. lev < size(tex%levels)) use_level = .true.
        end if
        if (use_level) then
            lw = tex%levels(lev + 1)%w
            lh = tex%levels(lev + 1)%h
        else
            lw = tex%w
            lh = tex%h
        end if
        if (lw <= 0 .or. lh <= 0) ok_dims = .false.
    end subroutine level_dims

    ! Sample one level, nearest or bilinear, honouring tex%wrap.
    pure function sample_level(tex, lev, u, v, bilinear) result(rgba)
        type(TextureImage), intent(in) :: tex
        integer, intent(in) :: lev
        real(dp), intent(in) :: u, v
        logical, intent(in) :: bilinear
        real(real32) :: rgba(4)
        integer :: lw, lh, i0, i1, j0, j1, ci, cj
        real(dp) :: wu, wv, x, y, fx, fy
        real(real32) :: c00(4), c10(4), c01(4), c11(4), top(4), bot(4)
        logical :: okd
        rgba = [1.0_real32, 0.0_real32, 1.0_real32, 1.0_real32]
        call level_dims(tex, lev, lw, lh, okd)
        if (.not. okd) return
        wu = wrap_coord(u, tex%wrap)
        wv = wrap_coord(v, tex%wrap)
        if (.not. bilinear) then
            ci = min(lw - 1, max(0, int(wu * real(lw, dp))))
            cj = min(lh - 1, max(0, int((1.0_dp - wv) * real(lh, dp))))
            rgba = level_texel(tex, lev, ci, cj)
            return
        end if
        x = wu * real(lw, dp) - 0.5_dp
        y = (1.0_dp - wv) * real(lh, dp) - 0.5_dp
        i0 = floor(x); fx = x - real(i0, dp)
        j0 = floor(y); fy = y - real(j0, dp)
        i1 = i0 + 1; j1 = j0 + 1
        c00 = level_texel(tex, lev, wrap_index(i0, lw, tex%wrap), &
                          wrap_index(j0, lh, tex%wrap))
        c10 = level_texel(tex, lev, wrap_index(i1, lw, tex%wrap), &
                          wrap_index(j0, lh, tex%wrap))
        c01 = level_texel(tex, lev, wrap_index(i0, lw, tex%wrap), &
                          wrap_index(j1, lh, tex%wrap))
        c11 = level_texel(tex, lev, wrap_index(i1, lw, tex%wrap), &
                          wrap_index(j1, lh, tex%wrap))
        top = c00 + real(fx, real32) * (c10 - c00)
        bot = c01 + real(fx, real32) * (c11 - c01)
        rgba = top + real(fy, real32) * (bot - top)
    end function sample_level

    ! Sample LINEAR rgba at (u, v) with level of detail lod.
    ! Honours tex%filter (0 nearest -- mip-nearest, 1 bilinear --
    ! nearest level, 2 trilinear) and tex%wrap.  Unloaded textures
    ! return magenta (1, 0, 1, 1) in linear space.
    pure function texture_sample_f(tex, u, v, lod) result(rgba)
        type(TextureImage), intent(in) :: tex
        real(dp), intent(in) :: u, v, lod
        real(real32) :: rgba(4)
        integer :: maxlev, l0, l1, lev
        real(dp) :: lodc, frac
        real(real32) :: a(4), b(4)
        rgba = [1.0_real32, 0.0_real32, 1.0_real32, 1.0_real32]
        if (.not. tex%loaded .or. .not. allocated(tex%pixels)) return
        if (tex%w <= 0 .or. tex%h <= 0) return
        maxlev = 0
        if (allocated(tex%levels)) maxlev = size(tex%levels) - 1
        lodc = min(real(maxlev, dp), max(0.0_dp, lod))
        select case (tex%filter)
        case (0)
            lev = nint(lodc)
            rgba = sample_level(tex, lev, u, v, .false.)
        case (1)
            lev = nint(lodc)
            rgba = sample_level(tex, lev, u, v, .true.)
        case default  ! trilinear
            l0 = floor(lodc)
            l1 = min(l0 + 1, maxlev)
            frac = lodc - real(l0, dp)
            a = sample_level(tex, l0, u, v, .true.)
            if (l1 == l0 .or. frac <= 0.0_dp) then
                rgba = a
            else
                b = sample_level(tex, l1, u, v, .true.)
                rgba = a + real(frac, real32) * (b - a)
            end if
        end select
    end function texture_sample_f

end module texture_3d
