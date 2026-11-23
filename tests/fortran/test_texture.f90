! test_texture.f90 -- tests for texture_3d (Wave A seat B51):
! PPM P3/P6 loading, nearest + REPEAT sampling, the magenta debug
! colour, and the frozen prim_uv contract (P14).
program test_texture
    use, intrinsic :: iso_fortran_env, only: int8, real32
    use math_3d
    use texture_3d
    use test_assert
    implicit none

    type(TextureImage) :: tex, empty_tex
    logical :: ok
    integer :: rgb(3), unit, i
    integer :: p6_bytes(12)
    ! Phase 4 additions
    type(TextureImage) :: tpng, tmip, tchk, tsrgb
    real(real32) :: frgba(4)
    integer(int8), allocatable :: pngbytes(:)
    integer :: fsize, ios2, cx, cy
    logical :: fexist
    character(len=256) :: fxdir
    real(dp) :: uv(2)
    character(len=*), parameter :: p3_path = '/tmp/test_texture_2x2.p3'
    character(len=*), parameter :: p6_path = '/tmp/test_texture_2x2.p6'
    character(len=*), parameter :: bad_path = '/tmp/test_texture_bad.p3'

    ! ---- unloaded texture samples as magenta (255,0,255) ----
    call assert_false(empty_tex%loaded, 'fresh TextureImage is not loaded')
    rgb = texture_sample(empty_tex, 0.25_dp, 0.25_dp)
    call assert_int_eq(255, rgb(1), 'unloaded sample R == 255 (magenta)')
    call assert_int_eq(0, rgb(2), 'unloaded sample G == 0 (magenta)')
    call assert_int_eq(255, rgb(3), 'unloaded sample B == 255 (magenta)')

    ! ---- missing file: ok = .false., no crash, still unloaded ----
    call texture_load_ppm('/tmp/test_texture_does_not_exist.ppm', tex, ok)
    call assert_false(ok, 'missing file gives ok=.false.')
    call assert_false(tex%loaded, 'missing file leaves texture unloaded')

    ! ---- malformed file: ok = .false., no crash ----
    open(newunit=unit, file=bad_path, status='replace', action='write')
    write(unit, '(A)') 'this is not a ppm at all'
    close(unit)
    call texture_load_ppm(bad_path, tex, ok)
    call assert_false(ok, 'malformed file gives ok=.false.')
    call assert_false(tex%loaded, 'malformed file leaves texture unloaded')

    ! ---- write a 2x2 P3: top row red, green; bottom row blue, white ----
    open(newunit=unit, file=p3_path, status='replace', action='write')
    write(unit, '(A)') 'P3'
    write(unit, '(A)') '# 2x2 test card'
    write(unit, '(A)') '2 2'
    write(unit, '(A)') '255'
    write(unit, '(A)') '255 0 0   0 255 0'
    write(unit, '(A)') '0 0 255   255 255 255'
    close(unit)

    call texture_load_ppm(p3_path, tex, ok)
    call assert_true(ok, 'P3 load ok')
    call assert_true(tex%loaded, 'P3 texture is loaded')
    call assert_int_eq(2, tex%w, 'P3 width == 2')
    call assert_int_eq(2, tex%h, 'P3 height == 2')

    ! Texel centres: u=0.25/0.75 are column centres, v=0.75 is the
    ! top row and v=0.25 the bottom row (v=1 at the top).
    rgb = texture_sample(tex, 0.25_dp, 0.75_dp)
    call assert_int_eq(255, rgb(1), 'P3 top-left R == 255 (red)')
    call assert_int_eq(0, rgb(2), 'P3 top-left G == 0 (red)')
    call assert_int_eq(0, rgb(3), 'P3 top-left B == 0 (red)')
    rgb = texture_sample(tex, 0.75_dp, 0.75_dp)
    call assert_int_eq(0, rgb(1), 'P3 top-right R == 0 (green)')
    call assert_int_eq(255, rgb(2), 'P3 top-right G == 255 (green)')
    call assert_int_eq(0, rgb(3), 'P3 top-right B == 0 (green)')
    rgb = texture_sample(tex, 0.25_dp, 0.25_dp)
    call assert_int_eq(0, rgb(1), 'P3 bottom-left R == 0 (blue)')
    call assert_int_eq(0, rgb(2), 'P3 bottom-left G == 0 (blue)')
    call assert_int_eq(255, rgb(3), 'P3 bottom-left B == 255 (blue)')
    rgb = texture_sample(tex, 0.75_dp, 0.25_dp)
    call assert_int_eq(255, rgb(1), 'P3 bottom-right R == 255 (white)')
    call assert_int_eq(255, rgb(2), 'P3 bottom-right G == 255 (white)')
    call assert_int_eq(255, rgb(3), 'P3 bottom-right B == 255 (white)')

    ! REPEAT wrapping: u=1.25 wraps to 0.25, v=-0.25 wraps to 0.75,
    ! so this is the top-left (red) texel again.
    rgb = texture_sample(tex, 1.25_dp, -0.25_dp)
    call assert_int_eq(255, rgb(1), 'wrap u=1.25 v=-0.25 R == 255 (red)')
    call assert_int_eq(0, rgb(2), 'wrap u=1.25 v=-0.25 G == 0 (red)')
    call assert_int_eq(0, rgb(3), 'wrap u=1.25 v=-0.25 B == 0 (red)')
    ! Negative u also wraps: u=-0.25 -> 0.75 (right column).
    rgb = texture_sample(tex, -0.25_dp, 0.25_dp)
    call assert_int_eq(255, rgb(1), 'wrap u=-0.25 R == 255 (white)')
    call assert_int_eq(255, rgb(3), 'wrap u=-0.25 B == 255 (white)')

    call texture_free(tex)
    call assert_false(tex%loaded, 'texture_free unloads the texture')
    rgb = texture_sample(tex, 0.25_dp, 0.75_dp)
    call assert_int_eq(255, rgb(3), 'sample after free is magenta B == 255')

    ! ---- P6 round-trip: same 2x2 image written as binary ----
    p6_bytes = [255, 0, 0, 0, 255, 0, 0, 0, 255, 255, 255, 255]
    open(newunit=unit, file=p6_path, status='replace', action='write', &
         access='stream', form='unformatted')
    write(unit) 'P6' // char(10)
    write(unit) '2 2' // char(10)
    write(unit) '255' // char(10)
    do i = 1, 12
        write(unit) achar(p6_bytes(i))
    end do
    close(unit)

    call texture_load_ppm(p6_path, tex, ok)
    call assert_true(ok, 'P6 load ok')
    call assert_int_eq(2, tex%w, 'P6 width == 2')
    call assert_int_eq(2, tex%h, 'P6 height == 2')
    rgb = texture_sample(tex, 0.25_dp, 0.75_dp)
    call assert_int_eq(255, rgb(1), 'P6 top-left R == 255 (red)')
    call assert_int_eq(0, rgb(3), 'P6 top-left B == 0 (red)')
    rgb = texture_sample(tex, 0.75_dp, 0.75_dp)
    call assert_int_eq(255, rgb(2), 'P6 top-right G == 255 (green)')
    rgb = texture_sample(tex, 0.25_dp, 0.25_dp)
    call assert_int_eq(255, rgb(3), 'P6 bottom-left B == 255 (blue)')
    rgb = texture_sample(tex, 0.75_dp, 0.25_dp)
    call assert_int_eq(255, rgb(1), 'P6 bottom-right R == 255 (white)')
    call assert_int_eq(255, rgb(2), 'P6 bottom-right G == 255 (white)')
    call assert_int_eq(255, rgb(3), 'P6 bottom-right B == 255 (white)')
    call texture_free(tex)

    ! ---- prim_uv: cube +Z face, u from +x and v from +y ----
    uv = prim_uv('cube', vec3_create(0.5_dp, 0.5_dp, 1.0_dp), &
                 [2.0_dp, 2.0_dp, 2.0_dp])
    call assert_real_close(0.75_dp, uv(1), 1.0e-12_dp, &
        'cube +Z face vertex (0.5,0.5,1) u == 0.75')
    call assert_real_close(0.75_dp, uv(2), 1.0e-12_dp, &
        'cube +Z face vertex (0.5,0.5,1) v == 0.75')
    uv = prim_uv('cube', vec3_create(-0.5_dp, -0.5_dp, 1.0_dp), &
                 [2.0_dp, 2.0_dp, 2.0_dp])
    call assert_real_close(0.25_dp, uv(1), 1.0e-12_dp, &
        'cube +Z face vertex (-0.5,-0.5,1) u == 0.25')
    call assert_real_close(0.25_dp, uv(2), 1.0e-12_dp, &
        'cube +Z face vertex (-0.5,-0.5,1) v == 0.25')
    uv = prim_uv('cube', vec3_create(0.0_dp, 1.0_dp, 1.0_dp), &
                 [2.0_dp, 2.0_dp, 2.0_dp])
    call assert_real_close(1.0_dp, uv(2), 1.0e-12_dp, &
        'cube +Z face top edge midpoint v == 1 (v=1 at top)')

    ! ---- prim_uv: sphere equator / poles / centre ----
    uv = prim_uv('sphere', vec3_create(1.0_dp, 0.0_dp, 0.0_dp), &
                 [2.0_dp, 2.0_dp, 2.0_dp])
    call assert_real_close(0.5_dp, uv(1), 1.0e-12_dp, &
        'sphere equator +X u == 0.5')
    call assert_real_close(0.5_dp, uv(2), 1.0e-12_dp, &
        'sphere equator +X v == 0.5')
    uv = prim_uv('sphere', vec3_create(0.0_dp, 0.0_dp, 1.0_dp), &
                 [2.0_dp, 2.0_dp, 2.0_dp])
    call assert_real_close(0.75_dp, uv(1), 1.0e-12_dp, &
        'sphere equator +Z u == 0.75')
    call assert_real_close(0.5_dp, uv(2), 1.0e-12_dp, &
        'sphere equator +Z v == 0.5')
    uv = prim_uv('sphere', vec3_create(0.0_dp, 1.0_dp, 0.0_dp), &
                 [2.0_dp, 2.0_dp, 2.0_dp])
    call assert_real_close(0.0_dp, uv(2), 1.0e-12_dp, &
        'sphere top pole v == 0 (acos(1)/pi)')
    uv = prim_uv('sphere', vec3_create(0.0_dp, -1.0_dp, 0.0_dp), &
                 [2.0_dp, 2.0_dp, 2.0_dp])
    call assert_real_close(1.0_dp, uv(2), 1.0e-12_dp, &
        'sphere bottom pole v == 1 (acos(-1)/pi)')
    uv = prim_uv('sphere', vec3_create(0.0_dp, 0.0_dp, 0.0_dp), &
                 [2.0_dp, 2.0_dp, 2.0_dp])
    call assert_real_close(0.5_dp, uv(1), 1.0e-12_dp, 'sphere r=0 u == 0.5')
    call assert_real_close(0.5_dp, uv(2), 1.0e-12_dp, 'sphere r=0 v == 0.5')

    ! ---- prim_uv: plane corners (0,0) and (1,1) ----
    uv = prim_uv('plane', vec3_create(-1.0_dp, 0.0_dp, -1.5_dp), &
                 [2.0_dp, 0.0_dp, 3.0_dp])
    call assert_real_close(0.0_dp, uv(1), 1.0e-12_dp, &
        'plane corner (-1,0,-1.5) u == 0')
    call assert_real_close(0.0_dp, uv(2), 1.0e-12_dp, &
        'plane corner (-1,0,-1.5) v == 0')
    uv = prim_uv('plane', vec3_create(1.0_dp, 0.0_dp, 1.5_dp), &
                 [2.0_dp, 0.0_dp, 3.0_dp])
    call assert_real_close(1.0_dp, uv(1), 1.0e-12_dp, &
        'plane corner (1,0,1.5) u == 1')
    call assert_real_close(1.0_dp, uv(2), 1.0e-12_dp, &
        'plane corner (1,0,1.5) v == 1')

    ! ---- prim_uv: cylinder top and torus outer equator (extras) ----
    uv = prim_uv('cylinder', vec3_create(1.0_dp, 1.0_dp, 0.0_dp), &
                 [2.0_dp, 2.0_dp, 2.0_dp])
    call assert_real_close(0.5_dp, uv(1), 1.0e-12_dp, &
        'cylinder +X top u == 0.5')
    call assert_real_close(1.0_dp, uv(2), 1.0e-12_dp, &
        'cylinder top v == 1')
    uv = prim_uv('torus', vec3_create(2.5_dp, 0.0_dp, 0.0_dp), &
                 [5.0_dp, 1.0_dp, 5.0_dp])
    call assert_real_close(0.5_dp, uv(1), 1.0e-12_dp, &
        'torus outer equator u == 0.5')
    call assert_real_close(0.5_dp, uv(2), 1.0e-12_dp, &
        'torus outer equator v == 0.5')

    ! ================================================================
    ! Phase 4: PNG decoding, dispatcher, mips, filtered sampling
    ! ================================================================
    fxdir = 'tests/fortran/fixtures/'
    inquire(file=trim(fxdir) // 'tex_rgb.png', exist=fexist)
    if (.not. fexist) fxdir = '../tests/fortran/fixtures/'
    inquire(file=trim(fxdir) // 'tex_rgb.png', exist=fexist)
    if (.not. fexist) fxdir = '../../tests/fortran/fixtures/'
    inquire(file=trim(fxdir) // 'tex_rgb.png', exist=fexist)
    call assert_true(fexist, 'PNG fixtures directory located')

    ! ---- PNG RGB 2x2 (filters Sub + Up exercised) ----
    call texture_load_png(trim(fxdir) // 'tex_rgb.png', tpng, ok)
    call assert_true(ok, 'PNG RGB load ok')
    call assert_int_eq(2, tpng%w, 'PNG RGB width == 2')
    call assert_int_eq(2, tpng%h, 'PNG RGB height == 2')
    call assert_int_eq(255, tpng%pixels(1, 1, 1), 'PNG RGB (1,1) R == 255')
    call assert_int_eq(0, tpng%pixels(2, 1, 1), 'PNG RGB (1,1) G == 0')
    call assert_int_eq(0, tpng%pixels(1, 2, 1), 'PNG RGB (2,1) R == 0')
    call assert_int_eq(255, tpng%pixels(2, 2, 1), 'PNG RGB (2,1) G == 255')
    call assert_int_eq(255, tpng%pixels(3, 1, 2), 'PNG RGB (1,2) B == 255')
    call assert_int_eq(255, tpng%pixels(1, 2, 2), 'PNG RGB (2,2) R == 255')
    call assert_int_eq(255, tpng%pixels(3, 2, 2), 'PNG RGB (2,2) B == 255')
    call assert_false(tpng%has_alpha, 'PNG RGB has_alpha == .false.')
    call assert_int_eq(255, tpng%alpha(1, 1), 'PNG RGB alpha defaults 255')
    call texture_free(tpng)

    ! ---- PNG RGBA 2x2 (filters Average + Paeth), alpha checked ----
    call texture_load_png(trim(fxdir) // 'tex_rgba.png', tpng, ok)
    call assert_true(ok, 'PNG RGBA load ok')
    call assert_true(tpng%has_alpha, 'PNG RGBA has_alpha == .true.')
    call assert_int_eq(10, tpng%pixels(1, 1, 1), 'PNG RGBA (1,1) R == 10')
    call assert_int_eq(30, tpng%pixels(3, 1, 1), 'PNG RGBA (1,1) B == 30')
    call assert_int_eq(0, tpng%alpha(1, 1), 'PNG RGBA (1,1) A == 0')
    call assert_int_eq(60, tpng%pixels(3, 2, 1), 'PNG RGBA (2,1) B == 60')
    call assert_int_eq(128, tpng%alpha(2, 1), 'PNG RGBA (2,1) A == 128')
    call assert_int_eq(90, tpng%pixels(3, 1, 2), 'PNG RGBA (1,2) B == 90')
    call assert_int_eq(200, tpng%alpha(1, 2), 'PNG RGBA (1,2) A == 200')
    call assert_int_eq(100, tpng%pixels(1, 2, 2), 'PNG RGBA (2,2) R == 100')
    call assert_int_eq(255, tpng%alpha(2, 2), 'PNG RGBA (2,2) A == 255')
    call texture_free(tpng)

    ! ---- PNG palette 2x2 ----
    call texture_load_png(trim(fxdir) // 'tex_palette.png', tpng, ok)
    call assert_true(ok, 'PNG palette load ok')
    call assert_int_eq(0, tpng%pixels(1, 1, 1), 'palette (1,1) R == 0')
    call assert_int_eq(255, tpng%pixels(1, 2, 1), 'palette (2,1) R == 255')
    call assert_int_eq(255, tpng%pixels(2, 1, 2), 'palette (1,2) G == 255')
    call assert_int_eq(255, tpng%pixels(3, 2, 2), 'palette (2,2) B == 255')
    call texture_free(tpng)

    ! ---- PNG grey 2x2 ----
    call texture_load_png(trim(fxdir) // 'tex_grey.png', tpng, ok)
    call assert_true(ok, 'PNG grey load ok')
    call assert_int_eq(0, tpng%pixels(1, 1, 1), 'grey (1,1) == 0')
    call assert_int_eq(85, tpng%pixels(2, 2, 1), 'grey (2,1) G == 85')
    call assert_int_eq(170, tpng%pixels(3, 1, 2), 'grey (1,2) B == 170')
    call assert_int_eq(255, tpng%pixels(1, 2, 2), 'grey (2,2) == 255')
    call texture_free(tpng)

    ! ---- PNG grey+alpha 2x2 (filter Sub) ----
    call texture_load_png(trim(fxdir) // 'tex_greyalpha.png', tpng, ok)
    call assert_true(ok, 'PNG grey+alpha load ok')
    call assert_true(tpng%has_alpha, 'grey+alpha has_alpha == .true.')
    call assert_int_eq(50, tpng%pixels(1, 1, 1), 'grey+a (1,1) == 50')
    call assert_int_eq(255, tpng%alpha(1, 1), 'grey+a (1,1) A == 255')
    call assert_int_eq(100, tpng%pixels(1, 2, 1), 'grey+a (2,1) == 100')
    call assert_int_eq(128, tpng%alpha(2, 1), 'grey+a (2,1) A == 128')
    call assert_int_eq(150, tpng%pixels(1, 1, 2), 'grey+a (1,2) == 150')
    call assert_int_eq(64, tpng%alpha(1, 2), 'grey+a (1,2) A == 64')
    call assert_int_eq(200, tpng%pixels(1, 2, 2), 'grey+a (2,2) == 200')
    call assert_int_eq(0, tpng%alpha(2, 2), 'grey+a (2,2) A == 0')
    call texture_free(tpng)

    ! ---- PNG 16-bit RGB: high-byte rule (filter Paeth on row 2) ----
    call texture_load_png(trim(fxdir) // 'tex_rgb16.png', tpng, ok)
    call assert_true(ok, 'PNG 16-bit load ok')
    call assert_int_eq(255, tpng%pixels(1, 1, 1), '16bit (1,1) R == 255')
    call assert_int_eq(128, tpng%pixels(2, 1, 1), '16bit (1,1) G == 128')
    call assert_int_eq(0, tpng%pixels(3, 1, 1), '16bit (1,1) B == 0')
    call assert_int_eq(18, tpng%pixels(1, 2, 1), '16bit (2,1) R == 18')
    call assert_int_eq(171, tpng%pixels(2, 2, 1), '16bit (2,1) G == 171')
    call assert_int_eq(255, tpng%pixels(3, 2, 1), '16bit (2,1) B == 255')
    call assert_int_eq(127, tpng%pixels(2, 1, 2), '16bit (1,2) G == 127')
    call assert_int_eq(222, tpng%pixels(1, 2, 2), '16bit (2,2) R == 222')
    call assert_int_eq(190, tpng%pixels(2, 2, 2), '16bit (2,2) G == 190')
    call assert_int_eq(1, tpng%pixels(3, 2, 2), '16bit (2,2) B == 1')
    call texture_free(tpng)

    ! ---- Stored-block IDAT fixture ----
    call texture_load_png(trim(fxdir) // 'tex_stored.png', tpng, ok)
    call assert_true(ok, 'PNG stored-block load ok')
    call assert_int_eq(9, tpng%pixels(1, 1, 1), 'stored (1,1) R == 9')
    call assert_int_eq(4, tpng%pixels(3, 2, 1), 'stored (2,1) B == 4')
    call assert_int_eq(1, tpng%pixels(3, 1, 2), 'stored (1,2) B == 1')
    call texture_free(tpng)

    ! ---- Fixed-Huffman IDAT fixture (4x4 gradient) ----
    call texture_load_png(trim(fxdir) // 'tex_fixed.png', tpng, ok)
    call assert_true(ok, 'PNG fixed-Huffman load ok')
    call assert_int_eq(4, tpng%w, 'fixed width == 4')
    call assert_int_eq(0, tpng%pixels(1, 1, 1), 'fixed (1,1) R == 0')
    call assert_int_eq(128, tpng%pixels(3, 1, 1), 'fixed (1,1) B == 128')
    call assert_int_eq(180, tpng%pixels(1, 4, 1), 'fixed (4,1) R == 180')
    call assert_int_eq(180, tpng%pixels(2, 1, 4), 'fixed (1,4) G == 180')
    call assert_int_eq(120, tpng%pixels(1, 3, 3), 'fixed (3,3) R == 120')
    call assert_int_eq(120, tpng%pixels(2, 3, 3), 'fixed (3,3) G == 120')
    call texture_free(tpng)

    ! ---- Dynamic-Huffman IDAT fixture (32x32 gradient) ----
    call texture_load_png(trim(fxdir) // 'tex_dynamic.png', tpng, ok)
    call assert_true(ok, 'PNG dynamic-Huffman load ok')
    call assert_int_eq(32, tpng%w, 'dynamic width == 32')
    call assert_int_eq(0, tpng%pixels(1, 1, 1), 'dynamic (1,1) R == 0')
    call assert_int_eq(248, tpng%pixels(1, 32, 32), 'dynamic (32,32) R')
    call assert_int_eq(248, tpng%pixels(2, 32, 32), 'dynamic (32,32) G')
    call assert_int_eq(248, tpng%pixels(3, 32, 32), 'dynamic (32,32) B')
    call assert_int_eq(128, tpng%pixels(1, 17, 9), 'dynamic (17,9) R')
    call assert_int_eq(64, tpng%pixels(2, 17, 9), 'dynamic (17,9) G')
    call assert_int_eq(96, tpng%pixels(3, 17, 9), 'dynamic (17,9) B')
    call texture_free(tpng)

    ! ---- Interlaced PNG is rejected (documented Adam7 limit) ----
    call texture_load_png(trim(fxdir) // 'tex_interlaced.png', tpng, ok)
    call assert_false(ok, 'interlaced PNG gives ok=.false.')
    call assert_false(tpng%loaded, 'interlaced PNG leaves tex unloaded')

    ! ---- png_decode directly on in-memory bytes (inflate check) ----
    open(newunit=unit, file=trim(fxdir) // 'tex_rgba.png', &
         status='old', action='read', access='stream', &
         form='unformatted', iostat=ios2)
    call assert_true(ios2 == 0, 'open RGBA fixture for png_decode')
    inquire(unit=unit, size=fsize)
    allocate(pngbytes(fsize))
    read(unit, iostat=ios2) (pngbytes(i), i = 1, fsize)
    close(unit)
    call png_decode(pngbytes, tpng, ok)
    call assert_true(ok, 'png_decode on memory bytes ok')
    call assert_int_eq(128, tpng%alpha(2, 1), 'png_decode alpha == 128')
    call assert_int_eq(120, tpng%pixels(3, 2, 2), 'png_decode B == 120')
    deallocate(pngbytes)
    call texture_free(tpng)
    ! Garbage bytes are rejected without crashing.
    allocate(pngbytes(16))
    pngbytes = 65_int8
    call png_decode(pngbytes, tpng, ok)
    call assert_false(ok, 'png_decode rejects garbage bytes')
    deallocate(pngbytes)

    ! ---- Dispatcher: texture_load sniffs magic bytes ----
    call texture_load(trim(fxdir) // 'tex_rgb.png', tpng, ok)
    call assert_true(ok, 'texture_load dispatches PNG ok')
    call assert_int_eq(255, tpng%pixels(2, 2, 1), 'dispatched PNG G == 255')
    call texture_free(tpng)
    call texture_load(p3_path, tpng, ok)
    call assert_true(ok, 'texture_load dispatches P3 ok')
    call assert_int_eq(255, tpng%pixels(1, 1, 1), 'dispatched P3 R == 255')
    call assert_int_eq(255, tpng%pixels(3, 1, 2), 'dispatched P3 B == 255')
    call texture_free(tpng)
    call texture_load(p6_path, tpng, ok)
    call assert_true(ok, 'texture_load dispatches P6 ok')
    call assert_int_eq(255, tpng%pixels(2, 2, 1), 'dispatched P6 G == 255')
    call texture_free(tpng)
    call texture_load(bad_path, tpng, ok)
    call assert_false(ok, 'texture_load rejects unknown magic')

    ! ---- Mipmaps: 4x4 known values, srgb off (linear == value/255)
    ! R = (x-1)*40 + (y-1)*10, G = 100, B = 255 - R ----
    tmip%w = 4; tmip%h = 4; tmip%loaded = .true.; tmip%srgb = .false.
    allocate(tmip%pixels(3, 4, 4))
    do cy = 1, 4
        do cx = 1, 4
            tmip%pixels(1, cx, cy) = (cx - 1) * 40 + (cy - 1) * 10
            tmip%pixels(2, cx, cy) = 100
            tmip%pixels(3, cx, cy) = 255 - tmip%pixels(1, cx, cy)
        end do
    end do
    call texture_build_mips(tmip)
    call assert_true(allocated(tmip%levels), 'mips allocated')
    call assert_int_eq(3, size(tmip%levels), 'mip level count == 3')
    call assert_int_eq(4, tmip%levels(1)%w, 'mip level 0 width == 4')
    call assert_int_eq(2, tmip%levels(2)%w, 'mip level 1 width == 2')
    call assert_int_eq(1, tmip%levels(3)%w, 'mip level 2 width == 1')
    call assert_int_eq(1, tmip%levels(3)%h, 'mip level 2 height == 1')
    ! Level 1 texel (1,1) = mean of R {0,40,10,50} = 25 -> 25/255
    call assert_real_close(real(tmip%levels(2)%rgba(1, 1, 1), dp), &
        25.0_dp / 255.0_dp, 1.0e-6_dp, 'mip L1 (1,1) R == 25/255')
    ! Level 1 texel (2,2) = mean of R {100,140,110,150} = 125
    call assert_real_close(real(tmip%levels(2)%rgba(1, 2, 2), dp), &
        125.0_dp / 255.0_dp, 1.0e-6_dp, 'mip L1 (2,2) R == 125/255')
    ! 1x1 level = global mean R = 75 -> 75/255; G stays 100/255
    call assert_real_close(real(tmip%levels(3)%rgba(1, 1, 1), dp), &
        75.0_dp / 255.0_dp, 1.0e-6_dp, 'mip L2 R == 75/255')
    call assert_real_close(real(tmip%levels(3)%rgba(2, 1, 1), dp), &
        100.0_dp / 255.0_dp, 1.0e-6_dp, 'mip L2 G == 100/255')
    call assert_real_close(real(tmip%levels(3)%rgba(4, 1, 1), dp), &
        1.0_dp, 1.0e-6_dp, 'mip L2 A == 1')
    ! Idempotent rebuild keeps the same chain.
    call texture_build_mips(tmip)
    call assert_int_eq(3, size(tmip%levels), 'mip rebuild still 3 levels')
    ! Build on an unloaded texture is a safe no-op.
    call texture_build_mips(empty_tex)
    call assert_false(allocated(empty_tex%levels), &
        'build_mips on unloaded texture is a no-op')

    ! ---- Trilinear / level sampling on the mip texture ----
    tmip%filter = 2; tmip%wrap = 1  ! trilinear, clamp
    ! (0.125, 0.875) is the centre of texel (1,1) of the 4x4 level 0.
    frgba = texture_sample_f(tmip, 0.125_dp, 0.875_dp, 0.0_dp)
    call assert_real_close(real(frgba(1), dp), 0.0_dp, 1.0e-6_dp, &
        'sample lod 0 at texel (1,1) centre R == 0')
    frgba = texture_sample_f(tmip, 0.125_dp, 0.875_dp, 1.0_dp)
    call assert_real_close(real(frgba(1), dp), 25.0_dp / 255.0_dp, &
        1.0e-6_dp, 'sample lod 1 R == 25/255')
    frgba = texture_sample_f(tmip, 0.125_dp, 0.875_dp, 0.5_dp)
    call assert_real_close(real(frgba(1), dp), 12.5_dp / 255.0_dp, &
        1.0e-6_dp, 'trilinear lod 0.5 blends levels R == 12.5/255')
    frgba = texture_sample_f(tmip, 0.125_dp, 0.875_dp, 99.0_dp)
    call assert_real_close(real(frgba(1), dp), 75.0_dp / 255.0_dp, &
        1.0e-6_dp, 'lod clamps to coarsest level R == 75/255')
    call texture_free(tmip)

    ! ---- Bilinear midpoint of a 2x2 checker == mean of 4 texels ----
    tchk%w = 2; tchk%h = 2; tchk%loaded = .true.; tchk%srgb = .false.
    tchk%filter = 1; tchk%wrap = 0
    allocate(tchk%pixels(3, 2, 2))
    tchk%pixels(:, 1, 1) = 0
    tchk%pixels(:, 2, 1) = 255
    tchk%pixels(:, 1, 2) = 255
    tchk%pixels(:, 2, 2) = 0
    frgba = texture_sample_f(tchk, 0.5_dp, 0.5_dp, 0.0_dp)
    call assert_real_close(real(frgba(1), dp), 0.5_dp, 1.0e-6_dp, &
        'bilinear checker midpoint R == 0.5')
    call assert_real_close(real(frgba(3), dp), 0.5_dp, 1.0e-6_dp, &
        'bilinear checker midpoint B == 0.5')
    call assert_real_close(real(frgba(4), dp), 1.0_dp, 1.0e-6_dp, &
        'bilinear checker midpoint A == 1')

    ! ---- Wrap modes at u = -0.25 / 1.25 (left col red, right green)
    tchk%pixels(:, 1, 1) = [255, 0, 0]
    tchk%pixels(:, 2, 1) = [0, 255, 0]
    tchk%pixels(:, 1, 2) = [255, 0, 0]
    tchk%pixels(:, 2, 2) = [0, 255, 0]
    tchk%filter = 0  ! nearest
    tchk%wrap = 0    ! repeat: -0.25 -> 0.75 (green), 1.25 -> 0.25 (red)
    frgba = texture_sample_f(tchk, -0.25_dp, 0.75_dp, 0.0_dp)
    call assert_real_close(real(frgba(2), dp), 1.0_dp, 1.0e-6_dp, &
        'wrap repeat u=-0.25 gives green')
    frgba = texture_sample_f(tchk, 1.25_dp, 0.75_dp, 0.0_dp)
    call assert_real_close(real(frgba(1), dp), 1.0_dp, 1.0e-6_dp, &
        'wrap repeat u=1.25 gives red')
    tchk%wrap = 1    ! clamp: -0.25 -> 0 (red), 1.25 -> 1 (green)
    frgba = texture_sample_f(tchk, -0.25_dp, 0.75_dp, 0.0_dp)
    call assert_real_close(real(frgba(1), dp), 1.0_dp, 1.0e-6_dp, &
        'wrap clamp u=-0.25 gives red')
    frgba = texture_sample_f(tchk, 1.25_dp, 0.75_dp, 0.0_dp)
    call assert_real_close(real(frgba(2), dp), 1.0_dp, 1.0e-6_dp, &
        'wrap clamp u=1.25 gives green')
    tchk%wrap = 2    ! mirror: -0.25 -> 0.25 (red), 1.25 -> 0.75 (green)
    frgba = texture_sample_f(tchk, -0.25_dp, 0.75_dp, 0.0_dp)
    call assert_real_close(real(frgba(1), dp), 1.0_dp, 1.0e-6_dp, &
        'wrap mirror u=-0.25 gives red')
    frgba = texture_sample_f(tchk, 1.25_dp, 0.75_dp, 0.0_dp)
    call assert_real_close(real(frgba(2), dp), 1.0_dp, 1.0e-6_dp, &
        'wrap mirror u=1.25 gives green')
    call texture_free(tchk)

    ! ---- sRGB decode in sampling; alpha never sRGB-decoded ----
    tsrgb%w = 1; tsrgb%h = 1; tsrgb%loaded = .true.
    tsrgb%filter = 0; tsrgb%wrap = 1
    allocate(tsrgb%pixels(3, 1, 1))
    allocate(tsrgb%alpha(1, 1))
    tsrgb%pixels(:, 1, 1) = 128
    tsrgb%alpha(1, 1) = 128
    tsrgb%has_alpha = .true.
    tsrgb%srgb = .true.
    frgba = texture_sample_f(tsrgb, 0.5_dp, 0.5_dp, 0.0_dp)
    call assert_real_close(real(frgba(1), dp), 0.2158_dp, 1.0e-3_dp, &
        'sRGB byte 128 -> linear ~= 0.2158')
    call assert_real_close(real(frgba(4), dp), 128.0_dp / 255.0_dp, &
        1.0e-6_dp, 'alpha 128 passes through un-decoded')
    tsrgb%srgb = .false.
    frgba = texture_sample_f(tsrgb, 0.5_dp, 0.5_dp, 0.0_dp)
    call assert_real_close(real(frgba(1), dp), 128.0_dp / 255.0_dp, &
        1.0e-6_dp, 'srgb off: byte 128 -> 128/255')
    call texture_free(tsrgb)

    ! ---- texture_sample_f on unloaded texture: magenta (1,0,1,1) ----
    frgba = texture_sample_f(empty_tex, 0.5_dp, 0.5_dp, 0.0_dp)
    call assert_real_close(real(frgba(1), dp), 1.0_dp, 1.0e-6_dp, &
        'sample_f unloaded R == 1 (magenta)')
    call assert_real_close(real(frgba(2), dp), 0.0_dp, 1.0e-6_dp, &
        'sample_f unloaded G == 0 (magenta)')
    call assert_real_close(real(frgba(4), dp), 1.0_dp, 1.0e-6_dp, &
        'sample_f unloaded A == 1')

    call test_summary()

end program test_texture
