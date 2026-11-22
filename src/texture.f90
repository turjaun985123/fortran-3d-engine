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
module texture_3d
    use, intrinsic :: iso_fortran_env, only: int8
    use math_3d, only: dp, vec3, PI
    implicit none
    private
    public :: TextureImage, texture_load_ppm, texture_free, &
              texture_sample, prim_uv

    type :: TextureImage
        integer :: w = 0
        integer :: h = 0
        integer, allocatable :: pixels(:, :, :)  ! (3, w, h), 0..255
        logical :: loaded = .false.
    end type TextureImage

contains

    subroutine texture_free(tex)
        type(TextureImage), intent(inout) :: tex
        if (allocated(tex%pixels)) deallocate(tex%pixels)
        tex%w = 0
        tex%h = 0
        tex%loaded = .false.
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

end module texture_3d
