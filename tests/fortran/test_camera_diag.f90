! test_camera_diag.f90 -- M1 diagnostic path (v3.0 Phase 5):
! camera_init_checked's optional status argument and the
! camera_view_status classifier.  Degenerate poses (eye ==
! target, or view direction (anti-)parallel to up) must report
! CAMERA_VIEW_DEGENERATE (1), a clean pose must report
! CAMERA_VIEW_CLEAN (0), and -- per ADR-1 -- the matrices built
! must be EXACTLY the ones the pre-Phase-5 code built: the
! camera_init path, whose view matrix is mat4_look_at with the
! Phase 0 fallback up (0,0,+1) when the view direction points
! along +up and (0,0,-1) when it points along -up.
program test_camera_diag
    use math_3d
    use camera_3d
    use test_assert
    use, intrinsic :: iso_fortran_env, only: int64
    use, intrinsic :: ieee_arithmetic, only: ieee_is_finite
    implicit none

    type(Camera) :: cam, ref
    type(mat4) :: expect
    type(vec3) :: eye, target
    logical :: ok
    integer :: status

    ! ---- clean pose: status 0, matrices identical to camera_init ----
    eye = vec3_create(3.0_dp, 2.5_dp, 4.0_dp)
    target = vec3_create(0.0_dp, 0.0_dp, 0.0_dp)
    call camera_init_checked(cam, eye, target, 60.0_dp, &
        4.0_dp / 3.0_dp, 0.1_dp, 100.0_dp, ok, status)
    call assert_true(ok, 'diag clean: ok true for valid params')
    call assert_int_eq(CAMERA_VIEW_CLEAN, status, &
        'diag clean: status is CAMERA_VIEW_CLEAN (0)')
    call camera_init(ref, eye, target, 60.0_dp, 4.0_dp / 3.0_dp, &
                     0.1_dp, 100.0_dp)
    call assert_true(mat_exact(cam%view_matrix, ref%view_matrix), &
        'diag clean: view matrix identical to camera_init')
    call assert_true(mat_exact(cam%proj_matrix, ref%proj_matrix), &
        'diag clean: proj matrix identical to camera_init')
    call assert_int_eq(CAMERA_VIEW_CLEAN, &
        camera_view_status(eye, target, &
            vec3_create(0.0_dp, 1.0_dp, 0.0_dp)), &
        'diag clean: camera_view_status is 0')

    ! ---- top-down: view dir anti-parallel to up (0,1,0) ----
    ! f = (0,-1,0); Phase 0 fallback up is (0,0,-1).
    eye = vec3_create(0.0_dp, 5.0_dp, 0.0_dp)
    call camera_init_checked(cam, eye, target, 60.0_dp, &
        4.0_dp / 3.0_dp, 0.1_dp, 100.0_dp, ok, status)
    call assert_true(ok, 'diag top-down: ok true for valid params')
    call assert_int_eq(CAMERA_VIEW_DEGENERATE, status, &
        'diag top-down: status is CAMERA_VIEW_DEGENERATE (1)')
    call camera_init(ref, eye, target, 60.0_dp, 4.0_dp / 3.0_dp, &
                     0.1_dp, 100.0_dp)
    call assert_true(mat_exact(cam%view_matrix, ref%view_matrix), &
        'diag top-down: view matrix identical to camera_init')
    expect = mat4_look_at(eye, target, &
                          vec3_create(0.0_dp, 0.0_dp, -1.0_dp))
    call assert_true(mat_exact(cam%view_matrix, expect), &
        'diag top-down: view matrix uses fallback up (0,0,-1)')

    ! ---- bottom-up: view dir parallel to up (0,1,0) ----
    ! f = (0,+1,0); Phase 0 fallback up is (0,0,+1).
    eye = vec3_create(0.0_dp, -5.0_dp, 0.0_dp)
    call camera_init_checked(cam, eye, target, 60.0_dp, &
        4.0_dp / 3.0_dp, 0.1_dp, 100.0_dp, ok, status)
    call assert_int_eq(CAMERA_VIEW_DEGENERATE, status, &
        'diag bottom-up: status is CAMERA_VIEW_DEGENERATE (1)')
    expect = mat4_look_at(eye, target, &
                          vec3_create(0.0_dp, 0.0_dp, 1.0_dp))
    call assert_true(mat_exact(cam%view_matrix, expect), &
        'diag bottom-up: view matrix uses fallback up (0,0,+1)')

    ! ---- eye == target: status 1, numeric behaviour unchanged ----
    eye = vec3_create(1.0_dp, 2.0_dp, 3.0_dp)
    target = vec3_create(1.0_dp, 2.0_dp, 3.0_dp)
    call camera_init_checked(cam, eye, target, 60.0_dp, &
        4.0_dp / 3.0_dp, 0.1_dp, 100.0_dp, ok, status)
    call assert_true(ok, 'diag eye==target: ok true (params valid)')
    call assert_int_eq(CAMERA_VIEW_DEGENERATE, status, &
        'diag eye==target: status is CAMERA_VIEW_DEGENERATE (1)')
    call camera_init(ref, eye, target, 60.0_dp, 4.0_dp / 3.0_dp, &
                     0.1_dp, 100.0_dp)
    call assert_true(mat_exact(cam%view_matrix, ref%view_matrix), &
        'diag eye==target: view matrix identical to pre-change code')
    call assert_true(mat_exact(cam%proj_matrix, ref%proj_matrix), &
        'diag eye==target: proj matrix identical to pre-change code')
    call assert_true(all(ieee_is_finite(cam%view_matrix%m)), &
        'diag eye==target: view matrix entries finite')

    ! ---- camera_view_status with a caller-supplied up ----
    call assert_int_eq(CAMERA_VIEW_DEGENERATE, &
        camera_view_status(vec3_create(0.0_dp, 0.0_dp, 0.0_dp), &
            vec3_create(0.0_dp, 0.0_dp, -5.0_dp), &
            vec3_create(0.0_dp, 0.0_dp, 1.0_dp)), &
        'diag custom up: anti-parallel up reports degenerate')
    call assert_int_eq(CAMERA_VIEW_CLEAN, &
        camera_view_status(vec3_create(0.0_dp, 0.0_dp, 0.0_dp), &
            vec3_create(0.0_dp, 0.0_dp, -5.0_dp), &
            vec3_create(0.0_dp, 1.0_dp, 0.0_dp)), &
        'diag custom up: perpendicular up reports clean')

    ! ---- status is independent of the parameter check ----
    eye = vec3_create(3.0_dp, 2.5_dp, 4.0_dp)
    target = vec3_create(0.0_dp, 0.0_dp, 0.0_dp)
    call camera_init_checked(cam, eye, target, 200.0_dp, 1.0_dp, &
                             0.1_dp, 100.0_dp, ok, status)
    call assert_false(ok, 'diag invalid fov: ok false')
    call assert_int_eq(CAMERA_VIEW_CLEAN, status, &
        'diag invalid fov: clean pose still reports status 0')

    ! ---- status argument is optional: old call form still works ----
    call camera_init_checked(cam, eye, target, 60.0_dp, 1.0_dp, &
                             0.1_dp, 100.0_dp, ok)
    call assert_true(ok, 'diag legacy call form: ok true')

    call test_summary()

contains

    ! Bit-exact matrix equality (transfer to int64 avoids the
    ! -Wcompare-reals warning; exactness is the whole point --
    ! ADR-1 requires identical matrices, not close ones).
    pure logical function mat_exact(a, b)
        type(mat4), intent(in) :: a, b
        mat_exact = all(transfer(a%m, [0_int64]) == &
                        transfer(b%m, [0_int64]))
    end function mat_exact

end program test_camera_diag
