program test_postprocess
    use math_3d, only: dp
    use renderer_3d, only: FrameBuffer, framebuffer_init
    use postprocess_3d, only: post_apply, post_apply_chain
    use test_assert
    implicit none

    type(FrameBuffer) :: fb, fb2
    integer :: before(3, 3, 3)
    real(dp) :: z_before(3, 3)
    character(len=10) :: chain_names(2)
    real(dp) :: chain_amounts(2)

    ! ---------- blur: 3x3 impulse, one pass ----------
    ! Centre 90, rest 0.  Every pixel's clamped 3x3 neighbourhood
    ! contains the centre exactly once: (90 + 4) / 9 = 10 everywhere.
    call framebuffer_init(fb, 3, 3)
    fb%pixels = 0
    fb%pixels(:, 2, 2) = 90
    call post_apply(fb, 'blur', 1.0_dp)
    call assert_true(all(fb%pixels == 10), &
        'blur 1 pass: 3x3 impulse 90 -> all 10')

    ! Two passes on the same impulse: first pass makes it uniform 10,
    ! second pass leaves a uniform field unchanged.
    call framebuffer_init(fb, 3, 3)
    fb%pixels = 0
    fb%pixels(:, 2, 2) = 90
    call post_apply(fb, 'blur', 2.0_dp)
    call assert_true(all(fb%pixels == 10), &
        'blur 2 passes: impulse -> all 10 (uniform after pass 1)')

    ! amount < 1 means zero passes: no-op.
    call framebuffer_init(fb, 3, 3)
    fb%pixels = 0
    fb%pixels(:, 2, 2) = 90
    before = fb%pixels
    call post_apply(fb, 'blur', 0.5_dp)
    call assert_true(all(fb%pixels == before), &
        'blur amount 0.5 (< 1 pass) is a no-op')

    ! 1x1 image: every neighbour clamps to the single pixel.
    call framebuffer_init(fb, 1, 1)
    fb%pixels(:, 1, 1) = 77
    call post_apply(fb, 'blur', 3.0_dp)
    call assert_int_eq(77, fb%pixels(1, 1, 1), &
        'blur on 1x1 leaves the pixel unchanged')

    ! 2x2 clamped-edge check, R channel only:
    !   values (x,y): (1,1)=0 (2,1)=90 (1,2)=0 (2,2)=0
    !   (1,1): sum 180 -> 20   (2,1): sum 360 -> 40
    !   (1,2): sum  90 -> 10   (2,2): sum 180 -> 20
    call framebuffer_init(fb, 2, 2)
    fb%pixels = 0
    fb%pixels(1, 2, 1) = 90
    call post_apply(fb, 'blur', 1.0_dp)
    call assert_int_eq(20, fb%pixels(1, 1, 1), 'blur 2x2 (1,1) == 20')
    call assert_int_eq(40, fb%pixels(1, 2, 1), 'blur 2x2 (2,1) == 40')
    call assert_int_eq(10, fb%pixels(1, 1, 2), 'blur 2x2 (1,2) == 10')
    call assert_int_eq(20, fb%pixels(1, 2, 2), 'blur 2x2 (2,2) == 20')
    call assert_true(all(fb%pixels(2:3, :, :) == 0), &
        'blur 2x2: zero channels stay zero')

    ! ---------- bloom (amount 1) ----------
    ! lum(200,200,200)/255 - 0.75 = 0.0343..; add 255*excess = 8.75
    !   -> 208.75 -> 209.  (100,0,0) is below threshold: unchanged.
    ! White: add 63.75, clamps to 255.
    ! (255,200,100): lum = 205.045, add 13.795 -> (255, 214, 114).
    call framebuffer_init(fb, 4, 1)
    fb%pixels(:, 1, 1) = [200, 200, 200]
    fb%pixels(:, 2, 1) = [100, 0, 0]
    fb%pixels(:, 3, 1) = [255, 255, 255]
    fb%pixels(:, 4, 1) = [255, 200, 100]
    call post_apply(fb, 'bloom', 1.0_dp)
    call assert_true(all(fb%pixels(:, 1, 1) == [209, 209, 209]), &
        'bloom: (200,200,200) -> 209')
    call assert_true(all(fb%pixels(:, 2, 1) == [100, 0, 0]), &
        'bloom: below-threshold pixel unchanged')
    call assert_true(all(fb%pixels(:, 3, 1) == [255, 255, 255]), &
        'bloom: white clamps to 255')
    call assert_true(all(fb%pixels(:, 4, 1) == [255, 214, 114]), &
        'bloom: (255,200,100) -> (255,214,114)')

    call framebuffer_init(fb, 1, 1)
    fb%pixels(:, 1, 1) = [255, 255, 255]
    call post_apply(fb, 'bloom', 0.0_dp)
    call assert_true(all(fb%pixels(:, 1, 1) == [255, 255, 255]), &
        'bloom amount 0 is a no-op')

    ! ---------- vignette: 3x3 all 100, amount 1 ----------
    ! d2: centre 0 -> 100; edge midpoints 0.5 -> 50; corners 1 -> 0.
    call framebuffer_init(fb, 3, 3)
    fb%pixels = 100
    call post_apply(fb, 'vignette', 1.0_dp)
    call assert_int_eq(100, fb%pixels(1, 2, 2), 'vignette centre == 100')
    call assert_int_eq(50, fb%pixels(1, 2, 1), 'vignette edge (2,1) == 50')
    call assert_int_eq(50, fb%pixels(1, 1, 2), 'vignette edge (1,2) == 50')
    call assert_int_eq(50, fb%pixels(1, 3, 2), 'vignette edge (3,2) == 50')
    call assert_int_eq(50, fb%pixels(1, 2, 3), 'vignette edge (2,3) == 50')
    call assert_int_eq(0, fb%pixels(1, 1, 1), 'vignette corner (1,1) == 0')
    call assert_int_eq(0, fb%pixels(1, 3, 3), 'vignette corner (3,3) == 0')

    call framebuffer_init(fb, 1, 1)
    fb%pixels(:, 1, 1) = 100
    call post_apply(fb, 'vignette', 1.0_dp)
    call assert_int_eq(100, fb%pixels(1, 1, 1), &
        'vignette on 1x1 (d2 == 0) is a no-op')

    call framebuffer_init(fb, 3, 3)
    fb%pixels = 100
    call post_apply(fb, 'vignette', 0.0_dp)
    call assert_true(all(fb%pixels == 100), 'vignette amount 0 is a no-op')

    ! ---------- gamma ----------
    ! amount 2: 255*sqrt(64/255) = 127.749.. -> 128; 0 -> 0; 255 -> 255.
    call framebuffer_init(fb, 3, 1)
    fb%pixels(:, 1, 1) = [64, 64, 64]
    fb%pixels(:, 2, 1) = [0, 0, 0]
    fb%pixels(:, 3, 1) = [255, 255, 255]
    call post_apply(fb, 'gamma', 2.0_dp)
    call assert_true(all(fb%pixels(:, 1, 1) == [128, 128, 128]), &
        'gamma 2: 64 -> 128')
    call assert_true(all(fb%pixels(:, 2, 1) == [0, 0, 0]), &
        'gamma 2: 0 stays 0')
    call assert_true(all(fb%pixels(:, 3, 1) == [255, 255, 255]), &
        'gamma 2: 255 stays 255')

    call framebuffer_init(fb, 1, 1)
    fb%pixels(:, 1, 1) = [37, 101, 199]
    call post_apply(fb, 'gamma', 1.0_dp)
    call assert_true(all(fb%pixels(:, 1, 1) == [37, 101, 199]), &
        'gamma amount 1 is an exact no-op')
    call post_apply(fb, 'gamma', 0.0_dp)
    call assert_true(all(fb%pixels(:, 1, 1) == [37, 101, 199]), &
        'gamma amount 0 is a no-op')
    call post_apply(fb, 'gamma', -2.0_dp)
    call assert_true(all(fb%pixels(:, 1, 1) == [37, 101, 199]), &
        'gamma negative amount is a no-op')

    ! ---------- grayscale ----------
    ! amount 1: lum(255,0,0)=76.245->76, lum(0,255,0)=149.685->150,
    !           lum(0,0,255)=29.07->29,  lum(10,20,30)=18.15->18.
    call framebuffer_init(fb, 4, 1)
    fb%pixels(:, 1, 1) = [255, 0, 0]
    fb%pixels(:, 2, 1) = [0, 255, 0]
    fb%pixels(:, 3, 1) = [0, 0, 255]
    fb%pixels(:, 4, 1) = [10, 20, 30]
    call post_apply(fb, 'grayscale', 1.0_dp)
    call assert_true(all(fb%pixels(:, 1, 1) == [76, 76, 76]), &
        'grayscale 1: red -> 76')
    call assert_true(all(fb%pixels(:, 2, 1) == [150, 150, 150]), &
        'grayscale 1: green -> 150')
    call assert_true(all(fb%pixels(:, 3, 1) == [29, 29, 29]), &
        'grayscale 1: blue -> 29')
    call assert_true(all(fb%pixels(:, 4, 1) == [18, 18, 18]), &
        'grayscale 1: (10,20,30) -> 18')

    ! amount 0.5 on red: R (255+76.245)/2 = 165.6225 -> 166,
    ! G/B (0+76.245)/2 = 38.1225 -> 38.
    call framebuffer_init(fb, 1, 1)
    fb%pixels(:, 1, 1) = [255, 0, 0]
    call post_apply(fb, 'grayscale', 0.5_dp)
    call assert_true(all(fb%pixels(:, 1, 1) == [166, 38, 38]), &
        'grayscale 0.5: red -> (166,38,38)')
    call post_apply(fb, 'grayscale', 0.0_dp)
    call assert_true(all(fb%pixels(:, 1, 1) == [166, 38, 38]), &
        'grayscale amount 0 is a no-op')

    ! ---------- sepia ----------
    ! amount 1 on (10,20,30): matrix gives (24.98, 22.25, 17.33)
    !   -> (25, 22, 17).  White: R/G targets clamp to 255,
    !   B target 0.937*255 = 238.935 -> 239.
    call framebuffer_init(fb, 2, 1)
    fb%pixels(:, 1, 1) = [10, 20, 30]
    fb%pixels(:, 2, 1) = [255, 255, 255]
    call post_apply(fb, 'sepia', 1.0_dp)
    call assert_true(all(fb%pixels(:, 1, 1) == [25, 22, 17]), &
        'sepia 1: (10,20,30) -> (25,22,17)')
    call assert_true(all(fb%pixels(:, 2, 1) == [255, 255, 239]), &
        'sepia 1: white -> (255,255,239)')

    ! amount 0.5 on (10,20,30): ((10+24.98)/2, (20+22.25)/2,
    ! (30+17.33)/2) = (17.49, 21.125, 23.665) -> (17, 21, 24).
    call framebuffer_init(fb, 1, 1)
    fb%pixels(:, 1, 1) = [10, 20, 30]
    call post_apply(fb, 'sepia', 0.5_dp)
    call assert_true(all(fb%pixels(:, 1, 1) == [17, 21, 24]), &
        'sepia 0.5: (10,20,30) -> (17,21,24)')

    ! ---------- case-insensitivity ----------
    call framebuffer_init(fb, 1, 1)
    fb%pixels(:, 1, 1) = [64, 64, 64]
    call post_apply(fb, 'GAMMA', 2.0_dp)
    call assert_int_eq(128, fb%pixels(1, 1, 1), &
        "name 'GAMMA' (upper case) applies gamma")
    call framebuffer_init(fb, 1, 1)
    fb%pixels(:, 1, 1) = [255, 0, 0]
    call post_apply(fb, 'GrayScale', 1.0_dp)
    call assert_int_eq(76, fb%pixels(1, 1, 1), &
        "name 'GrayScale' (mixed case) applies grayscale")

    ! ---------- unknown name: no-op, z-buffer untouched ----------
    call framebuffer_init(fb, 3, 3)
    fb%pixels = 42
    fb%pixels(:, 2, 2) = [10, 20, 30]
    before = fb%pixels
    z_before = fb%z_buffer
    call post_apply(fb, 'sharpen', 1.0_dp)
    call assert_true(all(fb%pixels == before), &
        "unknown name 'sharpen' is a no-op")
    call post_apply(fb, '', 1.0_dp)
    call assert_true(all(fb%pixels == before), &
        'empty name is a no-op')
    call post_apply(fb, 'gamma', 2.0_dp)
    call assert_true(all(fb%z_buffer == z_before), &
        'post filters never touch the z-buffer')

    ! ---------- chain: order matters ----------
    ! 3x3 impulse 255 (centre), rest 0.
    ! blur-then-gamma(2): blur -> all (255+4)/9 = 28;
    !   gamma -> 255*sqrt(28/255) = 84.498.. -> 84 everywhere.
    ! gamma(2)-then-blur: gamma leaves 255/0 unchanged;
    !   blur -> all 28.
    call framebuffer_init(fb, 3, 3)
    fb%pixels = 0
    fb%pixels(:, 2, 2) = 255
    chain_names = [character(len=10) :: 'blur', 'gamma']
    chain_amounts = [1.0_dp, 2.0_dp]
    call post_apply_chain(fb, chain_names, chain_amounts, 2)
    call assert_true(all(fb%pixels == 84), &
        'chain blur->gamma: impulse -> all 84')

    call framebuffer_init(fb2, 3, 3)
    fb2%pixels = 0
    fb2%pixels(:, 2, 2) = 255
    chain_names = [character(len=10) :: 'gamma', 'blur']
    chain_amounts = [2.0_dp, 1.0_dp]
    call post_apply_chain(fb2, chain_names, chain_amounts, 2)
    call assert_true(all(fb2%pixels == 28), &
        'chain gamma->blur: impulse -> all 28')
    call assert_true(fb%pixels(1, 2, 2) /= fb2%pixels(1, 2, 2), &
        'chain order matters: blur->gamma /= gamma->blur')

    call test_summary()

end program test_postprocess
