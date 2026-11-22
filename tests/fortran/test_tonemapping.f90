program test_tonemapping
    use math_3d, only: dp
    use renderer_3d, only: FrameBuffer, framebuffer_init
    use tonemapping_3d
    use test_assert
    implicit none

    type(FrameBuffer) :: fb
    integer :: before(3, 4, 3), x, y, k
    real(dp) :: z_before(4, 3)
    real(dp) :: rgb_out(3)
    real(dp) :: samples(6), prev_r, prev_a, cur_r, cur_a
    integer :: i
    ! ACES(1, exposure 1) from the Narkowicz formula by hand:
    !   (1*(2.51 + 0.03)) / (1*(2.43 + 0.59) + 0.14) = 2.54 / 3.16
    real(dp), parameter :: aces_at_1 = 2.54_dp / 3.16_dp

    samples = [0.0_dp, 0.25_dp, 0.5_dp, 1.0_dp, 2.0_dp, 4.0_dp]

    ! ---- mode constants ----
    call assert_int_eq(0, TM_NONE, 'TM_NONE == 0')
    call assert_int_eq(1, TM_REINHARD, 'TM_REINHARD == 1')
    call assert_int_eq(2, TM_ACES, 'TM_ACES == 2')

    ! ---- TM_NONE scalar: identity on 0..1, exposure ignored ----
    do i = 1, size(samples)
        if (samples(i) <= 1.0_dp) then
            call assert_real_close(samples(i), &
                tonemap_scalar(TM_NONE, samples(i), 1.0_dp), 0.0_dp, &
                'none scalar is identity on 0..1')
        end if
    end do
    call assert_real_close(0.4_dp, tonemap_scalar(TM_NONE, 0.4_dp, 7.5_dp), &
        0.0_dp, 'none scalar ignores exposure')
    call assert_real_close(1.0_dp, tonemap_scalar(TM_NONE, 1.5_dp, 1.0_dp), &
        0.0_dp, 'none scalar clamps above 1')
    call assert_real_close(0.0_dp, tonemap_scalar(TM_NONE, -0.5_dp, 1.0_dp), &
        0.0_dp, 'none scalar clamps below 0')

    ! ---- unknown mode falls back to the none clamp ----
    call assert_real_close(0.3_dp, tonemap_scalar(99, 0.3_dp, 5.0_dp), &
        0.0_dp, 'unknown mode scalar clamps like none')
    call assert_real_close(1.0_dp, tonemap_scalar(99, 2.0_dp, 1.0_dp), &
        0.0_dp, 'unknown mode scalar clamps above 1')

    ! ---- Reinhard ----
    call assert_real_close(0.0_dp, tonemap_scalar(TM_REINHARD, 0.0_dp, 1.0_dp), &
        0.0_dp, 'Reinhard(0) == 0')
    call assert_real_close(0.5_dp, tonemap_scalar(TM_REINHARD, 1.0_dp, 1.0_dp), &
        1.0e-15_dp, 'Reinhard(1, exp 1) == 0.5')
    prev_r = -1.0_dp
    do i = 1, size(samples)
        cur_r = tonemap_scalar(TM_REINHARD, samples(i), 1.0_dp)
        call assert_true(cur_r > prev_r, 'Reinhard is strictly monotonic')
        call assert_true(cur_r >= 0.0_dp .and. cur_r < 1.0_dp, &
            'Reinhard output in [0,1)')
        prev_r = cur_r
    end do

    ! ---- exposure doubles the effective input (Reinhard) ----
    call assert_real_close(tonemap_scalar(TM_REINHARD, 1.0_dp, 1.0_dp), &
        tonemap_scalar(TM_REINHARD, 0.5_dp, 2.0_dp), 0.0_dp, &
        'Reinhard exposure 2 on 0.5 == exposure 1 on 1.0')

    ! ---- ACES ----
    call assert_real_close(0.0_dp, tonemap_scalar(TM_ACES, 0.0_dp, 1.0_dp), &
        0.0_dp, 'ACES(0) == 0')
    call assert_true(tonemap_scalar(TM_ACES, 1.0_dp, 1.0_dp) > 0.7_dp .and. &
                     tonemap_scalar(TM_ACES, 1.0_dp, 1.0_dp) < 0.85_dp, &
        'ACES(1) in (0.7, 0.85)')
    call assert_real_close(aces_at_1, tonemap_scalar(TM_ACES, 1.0_dp, 1.0_dp), &
        1.0e-12_dp, 'ACES(1) == 2.54/3.16 (tight)')
    call assert_true(tonemap_scalar(TM_ACES, 4.0_dp, 1.0_dp) <= 1.0_dp, &
        'ACES(4) <= 1')
    call assert_true(tonemap_scalar(TM_ACES, 4.0_dp, 1.0_dp) >= 0.0_dp, &
        'ACES(4) >= 0')
    prev_a = -1.0_dp
    do i = 1, size(samples)
        cur_a = tonemap_scalar(TM_ACES, samples(i), 1.0_dp)
        call assert_true(cur_a > prev_a, 'ACES is strictly monotonic')
        call assert_true(cur_a >= 0.0_dp .and. cur_a <= 1.0_dp, &
            'ACES output in [0,1]')
        prev_a = cur_a
    end do

    ! ---- tonemap_rgb is channel-wise tonemap_scalar ----
    rgb_out = tonemap_rgb(TM_REINHARD, [0.0_dp, 1.0_dp, 0.5_dp], 1.0_dp)
    call assert_real_close(0.0_dp, rgb_out(1), 0.0_dp, 'rgb Reinhard ch1')
    call assert_real_close(0.5_dp, rgb_out(2), 1.0e-15_dp, 'rgb Reinhard ch2')
    call assert_real_close(1.0_dp / 3.0_dp, rgb_out(3), 1.0e-15_dp, &
        'rgb Reinhard ch3')
    rgb_out = tonemap_rgb(TM_NONE, [0.25_dp, 0.5_dp, 0.75_dp], 3.0_dp)
    call assert_real_close(0.25_dp, rgb_out(1), 0.0_dp, 'rgb none ch1 identity')
    call assert_real_close(0.5_dp, rgb_out(2), 0.0_dp, 'rgb none ch2 identity')
    call assert_real_close(0.75_dp, rgb_out(3), 0.0_dp, 'rgb none ch3 identity')

    ! ---- hand-built framebuffer ----
    call framebuffer_init(fb, 4, 3)
    do y = 1, 3
        do x = 1, 4
            do k = 1, 3
                fb%pixels(k, x, y) = mod(x * 37 + y * 91 + k * 53, 256)
            end do
        end do
    end do
    fb%pixels(:, 1, 1) = [0, 255, 128]
    before = fb%pixels
    z_before = fb%z_buffer

    ! ---- TM_NONE apply: bit-identical, even with a wild exposure ----
    call tonemap_apply(fb, TM_NONE, 3.7_dp)
    call assert_true(all(fb%pixels == before), &
        'none apply leaves pixels bit-identical')
    call assert_true(all(fb%z_buffer == z_before), &
        'none apply leaves z-buffer untouched')

    ! ---- Reinhard apply: 0 -> 0, 255 -> int(0.5*255) = 127, z untouched ----
    call tonemap_apply(fb, TM_REINHARD, 1.0_dp)
    call assert_int_eq(0, fb%pixels(1, 1, 1), 'Reinhard apply: 0 stays 0')
    call assert_int_eq(127, fb%pixels(2, 1, 1), &
        'Reinhard apply: 255 -> 127')
    call assert_true(all(fb%pixels >= 0) .and. all(fb%pixels <= 255), &
        'Reinhard apply: all pixels in 0..255')
    call assert_true(all(fb%z_buffer == z_before), &
        'Reinhard apply leaves z-buffer untouched')

    ! ---- ACES apply on a fresh copy: 255 -> int(ACES(1)*255) = 204 ----
    fb%pixels = before
    call tonemap_apply(fb, TM_ACES, 1.0_dp)
    call assert_int_eq(0, fb%pixels(1, 1, 1), 'ACES apply: 0 stays 0')
    call assert_int_eq(int(aces_at_1 * 255.0_dp), fb%pixels(2, 1, 1), &
        'ACES apply: 255 -> int(ACES(1)*255)')
    call assert_true(all(fb%pixels >= 0) .and. all(fb%pixels <= 255), &
        'ACES apply: all pixels in 0..255')

    ! ---- name mapping ----
    call assert_int_eq(TM_ACES, tonemap_mode_from_name('aces'), &
        "name 'aces' -> TM_ACES")
    call assert_int_eq(TM_REINHARD, tonemap_mode_from_name('reinhard'), &
        "name 'reinhard' -> TM_REINHARD")
    call assert_int_eq(TM_NONE, tonemap_mode_from_name('none'), &
        "name 'none' -> TM_NONE")
    call assert_int_eq(TM_NONE, tonemap_mode_from_name('filmic'), &
        'unknown name -> TM_NONE')
    call assert_int_eq(TM_NONE, tonemap_mode_from_name(''), &
        'empty name -> TM_NONE')

    call test_summary()

end program test_tonemapping
