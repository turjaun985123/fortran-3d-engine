! test_texture.f90 -- tests for texture_3d (Wave A seat B51):
! PPM P3/P6 loading, nearest + REPEAT sampling, the magenta debug
! colour, and the frozen prim_uv contract (P14).
program test_texture
    use math_3d
    use texture_3d
    use test_assert
    implicit none

    type(TextureImage) :: tex, empty_tex
    logical :: ok
    integer :: rgb(3), unit, i
    integer :: p6_bytes(12)
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

    call test_summary()

end program test_texture
