program test_clipping
    ! HK-R: homogeneous clip-space clipping (clip_triangle_frustum).
    use math_3d, only: dp
    use renderer_3d, only: ClipPoly, clip_triangle_frustum, CLIP_ATTR_COUNT
    use test_assert
    implicit none

    type(ClipPoly) :: poly
    real(dp) :: cin(4, 3), ain(CLIP_ATTR_COUNT, 3)
    integer :: k, found_mid
    logical :: same

    ! ---- fully inside: unchanged (same vertices, same order) ----
    cin(:, 1) = [0.0_dp, 0.0_dp, 0.0_dp, 1.0_dp]
    cin(:, 2) = [0.5_dp, 0.0_dp, 0.0_dp, 1.0_dp]
    cin(:, 3) = [0.0_dp, 0.5_dp, 0.0_dp, 1.0_dp]
    ain = 0.0_dp
    ain(1, :) = [10.0_dp, 20.0_dp, 30.0_dp]
    call clip_triangle_frustum(cin, ain, poly)
    call assert_int_eq(3, poly%n, 'clip: fully-inside triangle keeps 3 vertices')
    same = .true.
    do k = 1, 3
        if (any(abs(poly%clip(:, k) - cin(:, k)) > 1.0e-12_dp)) same = .false.
        if (abs(poly%attr(1, k) - ain(1, k)) > 1.0e-12_dp) same = .false.
    end do
    call assert_true(same, 'clip: fully-inside triangle vertices/attrs unchanged')

    ! ---- fully outside near plane (z < -w for all): empty ----
    cin(:, 1) = [0.0_dp, 0.0_dp, -2.0_dp, 1.0_dp]
    cin(:, 2) = [0.5_dp, 0.0_dp, -2.0_dp, 1.0_dp]
    cin(:, 3) = [0.0_dp, 0.5_dp, -2.0_dp, 1.0_dp]
    ain = 0.0_dp
    call clip_triangle_frustum(cin, ain, poly)
    call assert_int_eq(0, poly%n, 'clip: fully-outside (behind near) gives empty polygon')

    ! ---- one vertex behind near plane: quad (2 fan triangles) ----
    cin(:, 1) = [0.0_dp, 0.0_dp, -2.0_dp, 1.0_dp]
    cin(:, 2) = [0.5_dp, 0.0_dp, 0.0_dp, 1.0_dp]
    cin(:, 3) = [0.0_dp, 0.5_dp, 0.0_dp, 1.0_dp]
    ain = 0.0_dp
    call clip_triangle_frustum(cin, ain, poly)
    call assert_int_eq(4, poly%n, 'clip: one vertex behind near gives quad (4 verts)')
    call assert_int_eq(2, poly%n - 2, 'clip: quad fan-triangulates to 2 triangles')

    ! ---- interpolation midpoint correctness ----
    ! Edge v1->v2 crosses w+z=0 at t=0.5: v1 z=-2 (d=-1), v2 z=0 (d=+1),
    ! so the intersection is (0,0,-1,1) and attr1 goes 0 -> 10 giving 5.
    cin(:, 1) = [0.0_dp, 0.0_dp, -2.0_dp, 1.0_dp]
    cin(:, 2) = [0.0_dp, 0.0_dp, 0.0_dp, 1.0_dp]
    cin(:, 3) = [0.0_dp, 0.5_dp, 0.0_dp, 1.0_dp]
    ain = 0.0_dp
    ain(1, :) = [0.0_dp, 10.0_dp, 20.0_dp]
    call clip_triangle_frustum(cin, ain, poly)
    found_mid = 0
    do k = 1, poly%n
        if (abs(poly%clip(1, k)) < 1.0e-12_dp .and. &
            abs(poly%clip(2, k)) < 1.0e-12_dp .and. &
            abs(poly%clip(3, k) + 1.0_dp) < 1.0e-12_dp .and. &
            abs(poly%clip(4, k) - 1.0_dp) < 1.0e-12_dp) then
            found_mid = k
        end if
    end do
    call assert_true(found_mid > 0, 'clip: near-plane intersection at (0,0,-1,1) present')
    if (found_mid > 0) then
        call assert_real_close(5.0_dp, poly%attr(1, found_mid), 1.0e-12_dp, &
            'clip: interpolated attr at midpoint is 5 (half of 0->10)')
    end if

    ! ---- vertex behind camera (w < 0): must not survive ----
    cin(:, 1) = [0.0_dp, 0.0_dp, 0.0_dp, -1.0_dp]
    cin(:, 2) = [0.5_dp, 0.0_dp, 0.0_dp, 1.0_dp]
    cin(:, 3) = [0.0_dp, 0.5_dp, 0.0_dp, 1.0_dp]
    ain = 0.0_dp
    call clip_triangle_frustum(cin, ain, poly)
    call assert_true(poly%n >= 3, 'clip: w<0 vertex triangle still yields a polygon')
    same = .true.
    do k = 1, poly%n
        if (poly%clip(4, k) < 0.0_dp) same = .false.
        if (poly%clip(4, k) + poly%clip(3, k) < -1.0e-12_dp) same = .false.
        if (poly%clip(4, k) - poly%clip(3, k) < -1.0e-12_dp) same = .false.
    end do
    call assert_true(same, 'clip: all surviving vertices satisfy near/far planes, w>=0')

    call test_summary()
end program test_clipping
