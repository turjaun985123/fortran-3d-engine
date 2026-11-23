! test_look_at_degenerate.f90 -- M1 (v3.0 Phase 0): mat4_look_at with
! the view direction parallel to the up vector (top-down / bottom-up
! camera) must produce a finite, orthonormal view matrix instead of
! the old degenerate matrix whose right/up rows were the zero vector
! (cross(forward, up) == 0, normalised to 0).  Also covers the
! camera_init path built on it and a non-degenerate regression check.
program test_look_at_degenerate
    use math_3d
    use camera_3d
    use test_assert
    use, intrinsic :: ieee_arithmetic, only: ieee_is_finite
    implicit none

    type(mat4) :: v
    type(Camera) :: cam
    type(vec3) :: eye, target, got

    ! ---- top-down: eye (0,5,0) looking at the origin, up (0,1,0) ----
    eye = vec3_create(0.0_dp, 5.0_dp, 0.0_dp)
    target = vec3_create(0.0_dp, 0.0_dp, 0.0_dp)
    v = mat4_look_at(eye, target, vec3_create(0.0_dp, 1.0_dp, 0.0_dp))
    call assert_true(all(ieee_is_finite(v%m)), &
        'look_at top-down: all view matrix entries finite')
    call check_orthonormal(v, 'look_at top-down')
    got = mat4_transform_vec3(v, eye, .true.)
    call assert_vec3_close(vec3_create(0.0_dp, 0.0_dp, 0.0_dp), got, &
        1.0e-12_dp, 'look_at top-down: view maps eye to origin')
    got = mat4_transform_vec3(v, target, .true.)
    call assert_vec3_close(vec3_create(0.0_dp, 0.0_dp, -5.0_dp), got, &
        1.0e-12_dp, 'look_at top-down: view maps target to (0,0,-5)')

    ! ---- bottom-up: eye (0,-5,0) looking at the origin ----
    eye = vec3_create(0.0_dp, -5.0_dp, 0.0_dp)
    v = mat4_look_at(eye, target, vec3_create(0.0_dp, 1.0_dp, 0.0_dp))
    call assert_true(all(ieee_is_finite(v%m)), &
        'look_at bottom-up: all view matrix entries finite')
    call check_orthonormal(v, 'look_at bottom-up')
    got = mat4_transform_vec3(v, target, .true.)
    call assert_vec3_close(vec3_create(0.0_dp, 0.0_dp, -5.0_dp), got, &
        1.0e-12_dp, 'look_at bottom-up: view maps target to (0,0,-5)')

    ! ---- camera_init with a top-down pose uses the same guard ----
    eye = vec3_create(0.0_dp, 5.0_dp, 0.0_dp)
    call camera_init(cam, eye, target, 60.0_dp, 4.0_dp / 3.0_dp, &
                     0.1_dp, 100.0_dp)
    call assert_true(all(ieee_is_finite(cam%view_matrix%m)), &
        'camera_init top-down: view matrix finite')
    call check_orthonormal(cam%view_matrix, 'camera_init top-down')

    ! ---- non-degenerate regression: ordinary pose is unchanged ----
    eye = vec3_create(3.0_dp, 2.5_dp, 4.0_dp)
    v = mat4_look_at(eye, target, vec3_create(0.0_dp, 1.0_dp, 0.0_dp))
    call check_orthonormal(v, 'look_at ordinary pose')
    got = mat4_transform_vec3(v, target, .true.)
    call assert_vec3_close( &
        vec3_create(0.0_dp, 0.0_dp, -vec3_norm(eye)), got, 1.0e-12_dp, &
        'look_at ordinary pose: target maps to (0,0,-dist)')

    call test_summary()

contains

    ! The upper 3x3 rows of a view matrix must be unit length,
    ! pairwise orthogonal, and form a proper rotation (det == +1).
    subroutine check_orthonormal(m, label)
        type(mat4), intent(in) :: m
        character(len=*), intent(in) :: label
        type(vec3) :: r1, r2, r3
        real(dp) :: det

        r1 = vec3_create(m%m(1, 1), m%m(1, 2), m%m(1, 3))
        r2 = vec3_create(m%m(2, 1), m%m(2, 2), m%m(2, 3))
        r3 = vec3_create(m%m(3, 1), m%m(3, 2), m%m(3, 3))
        call assert_real_close(1.0_dp, vec3_norm(r1), 1.0e-12_dp, &
            label // ': row 1 is unit length')
        call assert_real_close(1.0_dp, vec3_norm(r2), 1.0e-12_dp, &
            label // ': row 2 is unit length')
        call assert_real_close(1.0_dp, vec3_norm(r3), 1.0e-12_dp, &
            label // ': row 3 is unit length')
        call assert_real_close(0.0_dp, vec3_dot(r1, r2), 1.0e-12_dp, &
            label // ': rows 1 and 2 are orthogonal')
        call assert_real_close(0.0_dp, vec3_dot(r1, r3), 1.0e-12_dp, &
            label // ': rows 1 and 3 are orthogonal')
        call assert_real_close(0.0_dp, vec3_dot(r2, r3), 1.0e-12_dp, &
            label // ': rows 2 and 3 are orthogonal')
        det = r1%x * (r2%y * r3%z - r2%z * r3%y) &
            - r1%y * (r2%x * r3%z - r2%z * r3%x) &
            + r1%z * (r2%x * r3%y - r2%y * r3%x)
        call assert_real_close(1.0_dp, det, 1.0e-12_dp, &
            label // ': 3x3 determinant is +1 (proper rotation)')
    end subroutine check_orthonormal

end program test_look_at_degenerate
