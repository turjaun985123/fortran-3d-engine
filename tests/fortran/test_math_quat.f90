! test_math_quat.f90 -- v3.0 Phase 5 (Seat Q): vec4 / mat3 / quat /
! general mat4_inverse in math_3d.
!
! Two layers:
!   1. FIXTURE-DRIVEN: reads tests/fixtures/math_vectors.json (the
!      golden numeric fixtures SHARED with the JS runtime tests in
!      Phase 7) through the repo's json_reader_3d and asserts every
!      case: euler->quat->euler round trips (incl. pitch +/-90
!      gimbal), axis-angle->quat->mat4 on vectors, slerp (incl. the
!      350deg -> 10deg shortest-path midpoint), mat4_inverse of a
!      TRS+shear matrix and of a general matrix, mat3 inverses.
!   2. DIRECT: operator overloads, quat multiply associativity,
!      quat_from_mat4 round trips (all trace branches), slerp
!      endpoints + t clamping, mat4_inverse vs mat4_inverse_rigid,
!      singular guards, gimbal rotation vs mat4_compose_trs.
!
! Fixture path: argv(1) if given, else the repo-relative default
! (the suite runs test programs from the repo root).
program test_math_quat
    use math_3d
    use json_reader_3d
    use test_assert
    implicit none

    character(len=512) :: path
    character(len=:), allocatable :: text
    type(json_doc) :: doc
    logical :: ok
    character(len=256) :: errmsg
    integer :: ncases, i, n_euler, n_axis, n_slerp, n_m4inv, n_m3inv

    if (command_argument_count() >= 1) then
        call get_command_argument(1, path)
    else
        path = 'tests/fixtures/math_vectors.json'
    end if

    call read_text_file(trim(path), text, ok)
    call assert_true(ok, 'fixture file readable: ' // trim(path))
    if (.not. ok) call test_summary()

    call json_parse(text, doc, ok, errmsg)
    call assert_true(ok, 'fixture JSON parses')
    if (.not. ok) then
        write(*, '(A)') '       parse error: ' // trim(errmsg)
        call test_summary()
    end if
    call assert_int_eq(4, json_kind(doc, doc%root), &
        'fixture root is a JSON array')

    ncases = json_arr_len(doc, doc%root)
    call assert_int_eq(17, ncases, 'fixture case count is 17')

    n_euler = 0; n_axis = 0; n_slerp = 0; n_m4inv = 0; n_m3inv = 0
    do i = 1, ncases
        call run_fixture_case(doc, i, n_euler, n_axis, n_slerp, &
                              n_m4inv, n_m3inv)
    end do
    call assert_int_eq(6, n_euler, 'fixture euler cases seen')
    call assert_int_eq(3, n_axis, 'fixture axis-angle cases seen')
    call assert_int_eq(4, n_slerp, 'fixture slerp cases seen')
    call assert_int_eq(2, n_m4inv, 'fixture mat4_inverse cases seen')
    call assert_int_eq(2, n_m3inv, 'fixture mat3_inverse cases seen')
    call json_free(doc)

    call direct_tests()
    call test_summary()

contains

    ! ---------------------------------------------------------------
    subroutine run_fixture_case(doc, idx, n_euler, n_axis, n_slerp, &
                                n_m4inv, n_m3inv)
        type(json_doc), intent(in) :: doc
        integer, intent(in) :: idx
        integer, intent(inout) :: n_euler, n_axis, n_slerp
        integer, intent(inout) :: n_m4inv, n_m3inv
        integer :: obj, child
        logical :: found
        character(len=64) :: kind, name

        call json_arr_at(doc, doc%root, idx, obj)
        call json_obj_get(doc, obj, 'name', child, found)
        name = ''
        if (found) name = json_str(doc, child)
        call json_obj_get(doc, obj, 'kind', child, found)
        kind = ''
        if (found) kind = json_str(doc, child)

        select case (trim(kind))
        case ('euler_quat_euler')
            n_euler = n_euler + 1
            call case_euler(doc, obj, trim(name))
        case ('axis_angle_mat4_vec3')
            n_axis = n_axis + 1
            call case_axis_angle(doc, obj, trim(name))
        case ('slerp')
            n_slerp = n_slerp + 1
            call case_slerp(doc, obj, trim(name))
        case ('mat4_inverse')
            n_m4inv = n_m4inv + 1
            call case_mat4_inverse(doc, obj, trim(name))
        case ('mat3_inverse')
            n_m3inv = n_m3inv + 1
            call case_mat3_inverse(doc, obj, trim(name))
        case default
            call assert_true(.false., &
                'fixture case has a known kind: ' // trim(name))
        end select
    end subroutine run_fixture_case

    subroutine case_euler(doc, obj, name)
        type(json_doc), intent(in) :: doc
        integer, intent(in) :: obj
        character(len=*), intent(in) :: name
        real(dp) :: e(3), qe(4), eo(3)
        type(quat) :: q
        type(vec3) :: e2
        call get_arr(doc, obj, 'euler_deg', e, 3)
        call get_arr(doc, obj, 'quat', qe, 4)
        call get_arr(doc, obj, 'euler_out_deg', eo, 3)
        q = quat_from_euler(vec3_create(e(1), e(2), e(3)))
        call assert_quat_close(q, quat_create(qe(1), qe(2), qe(3), qe(4)), &
            1.0e-12_dp, 'fixture ' // name // ': quat_from_euler')
        e2 = quat_to_euler(q)
        call assert_real_close(e2%x, eo(1), 1.0e-9_dp, &
            'fixture ' // name // ': euler_out x')
        call assert_real_close(e2%y, eo(2), 1.0e-9_dp, &
            'fixture ' // name // ': euler_out y')
        call assert_real_close(e2%z, eo(3), 1.0e-9_dp, &
            'fixture ' // name // ': euler_out z')
        call assert_quat_close(quat_from_euler(e2), q, 1.0e-12_dp, &
            'fixture ' // name // ': euler->quat->euler->quat identity')
    end subroutine case_euler

    subroutine case_axis_angle(doc, obj, name)
        type(json_doc), intent(in) :: doc
        integer, intent(in) :: obj
        character(len=*), intent(in) :: name
        real(dp) :: axis(3), vec(3), qe(4), rot(3), ang
        type(quat) :: q
        type(vec3) :: v, r
        call get_arr(doc, obj, 'axis', axis, 3)
        call get_arr(doc, obj, 'vec', vec, 3)
        call get_arr(doc, obj, 'quat', qe, 4)
        call get_arr(doc, obj, 'rotated', rot, 3)
        call get_num(doc, obj, 'angle_deg', ang)
        q = quat_from_axis_angle( &
            vec3_create(axis(1), axis(2), axis(3)), ang)
        call assert_quat_close(q, quat_create(qe(1), qe(2), qe(3), qe(4)), &
            1.0e-12_dp, 'fixture ' // name // ': quat_from_axis_angle')
        v = vec3_create(vec(1), vec(2), vec(3))
        r = vec3_create(rot(1), rot(2), rot(3))
        call assert_vec3_close(quat_rotate_vec3(q, v), r, 1.0e-9_dp, &
            'fixture ' // name // ': quat_rotate_vec3')
        call assert_vec3_close( &
            mat4_transform_vec3(quat_to_mat4(q), v, .false.), r, &
            1.0e-9_dp, 'fixture ' // name // ': quat_to_mat4 applied')
    end subroutine case_axis_angle

    subroutine case_slerp(doc, obj, name)
        type(json_doc), intent(in) :: doc
        integer, intent(in) :: obj
        character(len=*), intent(in) :: name
        real(dp) :: e1(3), e2(3), qe(4), t
        type(quat) :: q
        call get_arr(doc, obj, 'euler1_deg', e1, 3)
        call get_arr(doc, obj, 'euler2_deg', e2, 3)
        call get_arr(doc, obj, 'quat', qe, 4)
        call get_num(doc, obj, 't', t)
        q = quat_slerp(quat_from_euler(vec3_create(e1(1), e1(2), e1(3))), &
                       quat_from_euler(vec3_create(e2(1), e2(2), e2(3))), t)
        call assert_quat_close(q, quat_create(qe(1), qe(2), qe(3), qe(4)), &
            1.0e-12_dp, 'fixture ' // name // ': quat_slerp')
        call assert_real_close(sqrt(quat_dot(q, q)), 1.0_dp, 1.0e-12_dp, &
            'fixture ' // name // ': slerp result is unit')
    end subroutine case_slerp

    subroutine case_mat4_inverse(doc, obj, name)
        type(json_doc), intent(in) :: doc
        integer, intent(in) :: obj
        character(len=*), intent(in) :: name
        real(dp) :: mv(16), iv(16)
        type(mat4) :: m, inv, prod
        logical :: ok4
        integer :: i, j
        call get_arr(doc, obj, 'matrix', mv, 16)
        call get_arr(doc, obj, 'inverse', iv, 16)
        do i = 1, 4
            do j = 1, 4
                m%m(i, j) = mv((i - 1) * 4 + j)
            end do
        end do
        inv = mat4_inverse(m, ok4)
        call assert_true(ok4, 'fixture ' // name // ': mat4_inverse ok')
        call assert_real_close(mat4_maxdiff(inv, iv), 0.0_dp, 1.0e-9_dp, &
            'fixture ' // name // ': inverse matches fixture')
        prod = mat4_mult(m, inv)
        call assert_real_close(mat4_maxdiff_id(prod), 0.0_dp, 1.0e-9_dp, &
            'fixture ' // name // ': M * Minv == I')
    end subroutine case_mat4_inverse

    subroutine case_mat3_inverse(doc, obj, name)
        type(json_doc), intent(in) :: doc
        integer, intent(in) :: obj
        character(len=*), intent(in) :: name
        real(dp) :: mv(9), iv(9), det_exp
        type(mat3) :: a, inv, prod
        logical :: ok3, has_det
        integer :: i, j
        call get_arr(doc, obj, 'matrix', mv, 9)
        call get_arr(doc, obj, 'inverse', iv, 9)
        do i = 1, 3
            do j = 1, 3
                a%m(i, j) = mv((i - 1) * 3 + j)
            end do
        end do
        inv = mat3_inverse(a, ok3)
        call assert_true(ok3, 'fixture ' // name // ': mat3_inverse ok')
        call assert_real_close(mat3_maxdiff(inv, iv), 0.0_dp, 1.0e-9_dp, &
            'fixture ' // name // ': inverse matches fixture')
        prod = mat3_mult(a, inv)
        call assert_real_close(mat3_maxdiff_id(prod), 0.0_dp, 1.0e-9_dp, &
            'fixture ' // name // ': A * Ainv == I')
        call has_key(doc, obj, 'det', has_det)
        if (has_det) then
            call get_num(doc, obj, 'det', det_exp)
            call assert_real_close(mat3_determinant(a), det_exp, &
                1.0e-9_dp, 'fixture ' // name // ': determinant')
        end if
    end subroutine case_mat3_inverse

    ! ---------------------------------------------------------------
    ! JSON helpers
    ! ---------------------------------------------------------------

    subroutine get_arr(doc, obj, key, vals, n)
        type(json_doc), intent(in) :: doc
        integer, intent(in) :: obj, n
        character(len=*), intent(in) :: key
        real(dp), intent(out) :: vals(n)
        integer :: child, el, k
        logical :: found
        vals = 0.0_dp
        call json_obj_get(doc, obj, key, child, found)
        if (.not. found) then
            call assert_true(.false., 'fixture key present: ' // key)
            return
        end if
        if (json_arr_len(doc, child) /= n) then
            call assert_true(.false., &
                'fixture array length for key: ' // key)
            return
        end if
        do k = 1, n
            call json_arr_at(doc, child, k, el)
            vals(k) = json_num(doc, el, 0.0_dp)
        end do
    end subroutine get_arr

    subroutine get_num(doc, obj, key, val)
        type(json_doc), intent(in) :: doc
        integer, intent(in) :: obj
        character(len=*), intent(in) :: key
        real(dp), intent(out) :: val
        integer :: child
        logical :: found
        val = 0.0_dp
        call json_obj_get(doc, obj, key, child, found)
        if (.not. found) then
            call assert_true(.false., 'fixture key present: ' // key)
            return
        end if
        val = json_num(doc, child, 0.0_dp)
    end subroutine get_num

    subroutine has_key(doc, obj, key, found)
        type(json_doc), intent(in) :: doc
        integer, intent(in) :: obj
        character(len=*), intent(in) :: key
        logical, intent(out) :: found
        integer :: child
        call json_obj_get(doc, obj, key, child, found)
    end subroutine has_key

    subroutine read_text_file(path, text, ok)
        character(len=*), intent(in) :: path
        character(len=:), allocatable, intent(out) :: text
        logical, intent(out) :: ok
        integer :: u, ios, sz
        ok = .false.
        open(newunit=u, file=path, status='old', action='read', &
             access='stream', form='unformatted', iostat=ios)
        if (ios /= 0) return
        inquire(unit=u, size=sz)
        if (sz <= 0) then
            close(u)
            return
        end if
        allocate(character(len=sz) :: text)
        read(u, iostat=ios) text
        close(u)
        if (ios /= 0) return
        ok = .true.
    end subroutine read_text_file

    ! ---------------------------------------------------------------
    ! Compare helpers
    ! ---------------------------------------------------------------

    ! Quaternions are compared up to sign: q and -q are the same
    ! rotation, so the expected value is sign-aligned first.
    subroutine assert_quat_close(q, qe, tol, msg)
        type(quat), intent(in) :: q, qe
        real(dp), intent(in) :: tol
        character(len=*), intent(in) :: msg
        type(quat) :: e
        e = qe
        if (quat_dot(q, qe) < 0.0_dp) e = quat_negate(qe)
        call assert_real_close(q%x, e%x, tol, msg // ' [x]')
        call assert_real_close(q%y, e%y, tol, msg // ' [y]')
        call assert_real_close(q%z, e%z, tol, msg // ' [z]')
        call assert_real_close(q%w, e%w, tol, msg // ' [w]')
    end subroutine assert_quat_close

    function mat4_maxdiff(m, flat_rowmajor) result(d)
        type(mat4), intent(in) :: m
        real(dp), intent(in) :: flat_rowmajor(16)
        real(dp) :: d
        integer :: i, j
        d = 0.0_dp
        do i = 1, 4
            do j = 1, 4
                d = max(d, abs(m%m(i, j) - flat_rowmajor((i - 1) * 4 + j)))
            end do
        end do
    end function mat4_maxdiff

    function mat4_maxdiff_id(m) result(d)
        type(mat4), intent(in) :: m
        real(dp) :: d
        integer :: i, j
        d = 0.0_dp
        do i = 1, 4
            do j = 1, 4
                if (i == j) then
                    d = max(d, abs(m%m(i, j) - 1.0_dp))
                else
                    d = max(d, abs(m%m(i, j)))
                end if
            end do
        end do
    end function mat4_maxdiff_id

    function mat3_maxdiff(m, flat_rowmajor) result(d)
        type(mat3), intent(in) :: m
        real(dp), intent(in) :: flat_rowmajor(9)
        real(dp) :: d
        integer :: i, j
        d = 0.0_dp
        do i = 1, 3
            do j = 1, 3
                d = max(d, abs(m%m(i, j) - flat_rowmajor((i - 1) * 3 + j)))
            end do
        end do
    end function mat3_maxdiff

    function mat3_maxdiff_id(m) result(d)
        type(mat3), intent(in) :: m
        real(dp) :: d
        integer :: i, j
        d = 0.0_dp
        do i = 1, 3
            do j = 1, 3
                if (i == j) then
                    d = max(d, abs(m%m(i, j) - 1.0_dp))
                else
                    d = max(d, abs(m%m(i, j)))
                end if
            end do
        end do
    end function mat3_maxdiff_id

    function mat3_maxdiff3(a, b) result(d)
        type(mat3), intent(in) :: a, b
        real(dp) :: d
        integer :: i, j
        d = 0.0_dp
        do i = 1, 3
            do j = 1, 3
                d = max(d, abs(a%m(i, j) - b%m(i, j)))
            end do
        end do
    end function mat3_maxdiff3

    function mat4_maxdiff4(a, b) result(d)
        type(mat4), intent(in) :: a, b
        real(dp) :: d
        integer :: i, j
        d = 0.0_dp
        do i = 1, 4
            do j = 1, 4
                d = max(d, abs(a%m(i, j) - b%m(i, j)))
            end do
        end do
    end function mat4_maxdiff4

    function mat4_upper_maxdiff(a, b) result(d)
        type(mat4), intent(in) :: a, b
        real(dp) :: d
        integer :: i, j
        d = 0.0_dp
        do i = 1, 3
            do j = 1, 3
                d = max(d, abs(a%m(i, j) - b%m(i, j)))
            end do
        end do
    end function mat4_upper_maxdiff


    ! ---------------------------------------------------------------
    ! Direct assertions (not fixture-driven)
    ! ---------------------------------------------------------------

    subroutine direct_tests()
        type(vec4) :: v4a, v4b, v4c
        type(mat3) :: a3, b3, c3
        type(mat4) :: m4a, m4b, inv_g, inv_r
        type(quat) :: qa, qb, qc, ql, qr, qe
        type(vec3) :: v, eul
        logical :: ok4, ok3
        type(mat4) :: mtmp

        ! ---------- vec4 ----------
        v4a = vec4_create(1.0_dp, 2.0_dp, 3.0_dp, 4.0_dp)
        v4b = vec4_create(-2.0_dp, 0.5_dp, 1.0_dp, -1.0_dp)
        v4c = vec4_add(v4a, v4b)
        call assert_real_close(v4c%x, -1.0_dp, 0.0_dp, 'vec4_add x')
        call assert_real_close(v4c%y, 2.5_dp, 0.0_dp, 'vec4_add y')
        call assert_real_close(v4c%z, 4.0_dp, 0.0_dp, 'vec4_add z')
        call assert_real_close(v4c%w, 3.0_dp, 0.0_dp, 'vec4_add w')
        v4c = vec4_sub(v4a, v4b)
        call assert_real_close(v4c%x, 3.0_dp, 0.0_dp, 'vec4_sub x')
        call assert_real_close(v4c%w, 5.0_dp, 0.0_dp, 'vec4_sub w')
        v4c = vec4_scale(v4a, 2.0_dp)
        call assert_real_close(v4c%z, 6.0_dp, 0.0_dp, 'vec4_scale z')
        call assert_real_close(vec4_dot(v4a, v4b), -2.0_dp, 0.0_dp, &
            'vec4_dot')
        call assert_real_close( &
            vec4_norm(vec4_create(1.0_dp, 2.0_dp, 2.0_dp, 0.0_dp)), &
            3.0_dp, 1.0e-15_dp, 'vec4_norm')
        call assert_real_close( &
            vec4_length(vec4_create(1.0_dp, 2.0_dp, 2.0_dp, 0.0_dp)), &
            3.0_dp, 1.0e-15_dp, 'vec4_length == vec4_norm')
        v4c = vec4_normalize(vec4_create(1.0_dp, 2.0_dp, 2.0_dp, 0.0_dp))
        call assert_real_close(v4c%y, 2.0_dp / 3.0_dp, 1.0e-15_dp, &
            'vec4_normalize y')
        call assert_real_close(vec4_norm(v4c), 1.0_dp, 1.0e-15_dp, &
            'vec4_normalize gives unit length')
        v4c = v4a + v4b
        call assert_real_close(v4c%y, 2.5_dp, 0.0_dp, &
            'operator(+) vec4 matches vec4_add')
        v4c = v4a - v4b
        call assert_real_close(v4c%y, 1.5_dp, 0.0_dp, &
            'operator(-) vec4 matches vec4_sub')

        ! ---------- mat3 ----------
        m4a = mat4_compose_trs(vec3_create(5.0_dp, -3.0_dp, 2.0_dp), &
                               vec3_create(10.0_dp, 20.0_dp, 30.0_dp), &
                               vec3_create(2.0_dp, 3.0_dp, 4.0_dp))
        a3 = mat3_from_mat4(m4a)
        call assert_real_close(a3%m(1, 1), m4a%m(1, 1), 0.0_dp, &
            'mat3_from_mat4 copies upper 3x3')
        call assert_real_close(a3%m(3, 2), m4a%m(3, 2), 0.0_dp, &
            'mat3_from_mat4 copies upper 3x3 (3,2)')
        call assert_real_close(mat3_determinant(a3), &
            mat4_determinant(m4a), 1.0e-12_dp, &
            'mat3_determinant == mat4_determinant of upper 3x3')
        b3 = mat3_transpose(mat3_transpose(a3))
        call assert_real_close(mat3_maxdiff3(b3, a3), 0.0_dp, 0.0_dp, &
            'mat3_transpose twice is the identity map')
        m4b = mat4_compose_trs(vec3_create(0.0_dp, 0.0_dp, 0.0_dp), &
                               vec3_create(-15.0_dp, 5.0_dp, 80.0_dp), &
                               vec3_create(1.0_dp, 1.0_dp, 1.0_dp))
        mtmp = mat4_mult(m4a, m4b)
        c3 = mat3_mult(a3, mat3_from_mat4(m4b))
        call assert_real_close(mat3_maxdiff3(c3, mat3_from_mat4(mtmp)), &
            0.0_dp, 1.0e-12_dp, &
            'mat3_mult agrees with mat4_mult upper 3x3')
        v = vec3_create(0.3_dp, -1.2_dp, 2.5_dp)
        call assert_vec3_close(mat3_mult_vec3(a3, v), &
            mat4_transform_vec3(m4a, v, .false.), 1.0e-12_dp, &
            'mat3_mult_vec3 agrees with mat4_transform_vec3')
        c3 = a3 * mat3_from_mat4(m4b)
        call assert_real_close(mat3_maxdiff3(c3, mat3_from_mat4(mtmp)), &
            0.0_dp, 1.0e-12_dp, &
            'operator(*) mat3*mat3 matches mat3_mult')
        call assert_vec3_close(a3 * v, mat3_mult_vec3(a3, v), 0.0_dp, &
            'operator(*) mat3*vec3 matches mat3_mult_vec3')
        c3 = mat3_mult(mat3_identity(), a3)
        call assert_real_close(mat3_maxdiff3(c3, a3), 0.0_dp, 0.0_dp, &
            'mat3_identity is a left identity')
        ! singular mat3: row 2 = 2 * row 1 -> det exactly 0
        b3 = mat3_create(1.0_dp, 2.0_dp, 3.0_dp, &
                         2.0_dp, 4.0_dp, 6.0_dp, &
                         1.0_dp, 0.0_dp, 1.0_dp)
        c3 = mat3_inverse(b3, ok3)
        call assert_false(ok3, 'mat3_inverse singular: ok is false')
        call assert_real_close(mat3_maxdiff_id(c3), 0.0_dp, 0.0_dp, &
            'mat3_inverse singular: result is identity')
        c3 = mat3_inverse(b3)  ! no ok argument: must not crash
        call assert_real_close(mat3_maxdiff_id(c3), 0.0_dp, 0.0_dp, &
            'mat3_inverse singular without ok: identity')

        ! ---------- quat basics ----------
        v = vec3_create(1.0_dp, 2.0_dp, 3.0_dp)
        call assert_vec3_close(quat_rotate_vec3(quat_identity(), v), v, &
            0.0_dp, 'quat_identity rotates nothing')
        qa = quat_from_euler(vec3_create(20.0_dp, 30.0_dp, 40.0_dp))
        call assert_quat_close( &
            quat_multiply(qa, quat_conjugate(qa)), quat_identity(), &
            1.0e-12_dp, 'q * conjugate(q) == identity (unit q)')
        qb = quat_scale(qa, 2.0_dp)  ! non-unit
        call assert_quat_close( &
            quat_multiply(qb, quat_inverse(qb)), quat_identity(), &
            1.0e-12_dp, 'q * inverse(q) == identity (non-unit q)')
        call assert_quat_close( &
            quat_normalize(quat_create(0.0_dp, 0.0_dp, 0.0_dp, 0.0_dp)), &
            quat_identity(), 0.0_dp, &
            'quat_normalize of zero quat is identity')

        ! quat vs mat4_compose_trs on a general Euler triple
        eul = vec3_create(15.0_dp, -60.0_dp, 120.0_dp)
        qa = quat_from_euler(eul)
        m4a = mat4_compose_trs(vec3_create(0.0_dp, 0.0_dp, 0.0_dp), &
                               eul, vec3_create(1.0_dp, 1.0_dp, 1.0_dp))
        call assert_real_close( &
            mat4_upper_maxdiff(quat_to_mat4(qa), m4a), 0.0_dp, &
            1.0e-12_dp, 'quat_to_mat4 == mat4_compose_trs rotation')
        call assert_vec3_close(quat_rotate_vec3(qa, v), &
            mat4_transform_vec3(m4a, v, .false.), 1.0e-12_dp, &
            'quat_rotate_vec3 == compose_trs applied')

        ! ---------- multiply order + associativity ----------
        qa = quat_from_axis_angle(vec3_create(0.0_dp, 1.0_dp, 0.0_dp), &
                                  90.0_dp)
        qb = quat_from_axis_angle(vec3_create(1.0_dp, 0.0_dp, 0.0_dp), &
                                  90.0_dp)
        ! (yaw90 * pitch90) applies pitch first: (0,0,1) -> pitch90
        ! sends z to -y... then yaw leaves y alone: expect (0,-1,0)
        call assert_vec3_close( &
            quat_rotate_vec3(quat_multiply(qa, qb), &
                             vec3_create(0.0_dp, 0.0_dp, 1.0_dp)), &
            vec3_create(0.0_dp, -1.0_dp, 0.0_dp), 1.0e-12_dp, &
            'quat_multiply(a,b) applies b then a')
        qa = quat_from_euler(vec3_create(20.0_dp, 30.0_dp, 40.0_dp))
        qb = quat_from_axis_angle(vec3_create(1.0_dp, 1.0_dp, 0.0_dp), &
                                  55.0_dp)
        qc = quat_from_euler(vec3_create(-70.0_dp, 15.0_dp, 100.0_dp))
        ql = quat_multiply(quat_multiply(qa, qb), qc)
        qr = quat_multiply(qa, quat_multiply(qb, qc))
        call assert_quat_close(ql, qr, 1.0e-12_dp, &
            'quat_multiply is associative')
        qe = qa * qb
        call assert_quat_close(qe, quat_multiply(qa, qb), 0.0_dp, &
            'operator(*) quat*quat matches quat_multiply')
        qe = qa + qb
        call assert_quat_close(qe, quat_add(qa, qb), 0.0_dp, &
            'operator(+) quat matches quat_add')
        qe = qa - qb
        call assert_quat_close(qe, quat_sub(qa, qb), 0.0_dp, &
            'operator(-) quat matches quat_sub')

        ! ---------- quat_from_mat4 round trips (all branches) ----------
        call check_mat4_roundtrip( &
            vec3_create(20.0_dp, 35.0_dp, -50.0_dp), 'trace branch')
        call check_mat4_roundtrip( &
            vec3_create(180.0_dp, 0.0_dp, 0.0_dp), 'x-diagonal branch')
        call check_mat4_roundtrip( &
            vec3_create(0.0_dp, 180.0_dp, 0.0_dp), 'y-diagonal branch')
        call check_mat4_roundtrip( &
            vec3_create(0.0_dp, 0.0_dp, 180.0_dp), 'z-diagonal branch')

        ! ---------- slerp endpoints, clamping, shortest path ------
        qa = quat_from_euler(vec3_create(10.0_dp, 20.0_dp, 30.0_dp))
        qb = quat_from_euler(vec3_create(-40.0_dp, 80.0_dp, 5.0_dp))
        call assert_quat_close(quat_slerp(qa, qb, 0.0_dp), qa, &
            1.0e-12_dp, 'slerp t=0 is exactly q1')
        call assert_quat_close(quat_slerp(qa, qb, 1.0_dp), qb, &
            1.0e-12_dp, 'slerp t=1 is exactly q2')
        call assert_quat_close(quat_slerp(qa, qb, -0.5_dp), qa, &
            1.0e-12_dp, 'slerp t<0 clamps to q1')
        call assert_quat_close(quat_slerp(qa, qb, 1.5_dp), qb, &
            1.0e-12_dp, 'slerp t>1 clamps to q2')
        ! 350deg -> 10deg yaw: the short way passes through yaw 0
        qa = quat_from_euler(vec3_create(0.0_dp, 350.0_dp, 0.0_dp))
        qb = quat_from_euler(vec3_create(0.0_dp, 10.0_dp, 0.0_dp))
        qe = quat_slerp(qa, qb, 0.5_dp)
        call assert_real_close(abs(quat_dot(qe, quat_identity())), &
            1.0_dp, 1.0e-9_dp, &
            'slerp 350->10 midpoint is the yaw-0 quat (shortest path)')
        call assert_vec3_close( &
            quat_rotate_vec3(qe, vec3_create(1.0_dp, 0.0_dp, 0.0_dp)), &
            vec3_create(1.0_dp, 0.0_dp, 0.0_dp), 1.0e-9_dp, &
            'slerp 350->10 midpoint rotates as yaw 0')

        ! ---------- gimbal: quat vs mat4_compose_trs ---------------
        call check_gimbal(vec3_create(0.0_dp, 90.0_dp, 0.0_dp), &
            'euler(0,90,0)')
        call check_gimbal(vec3_create(90.0_dp, 20.0_dp, 15.0_dp), &
            'euler(90,20,15) pitch gimbal')
        call check_gimbal(vec3_create(-90.0_dp, -30.0_dp, 45.0_dp), &
            'euler(-90,-30,45) pitch gimbal')
        eul = quat_to_euler(quat_from_euler( &
            vec3_create(0.0_dp, 90.0_dp, 0.0_dp)))
        call assert_vec3_close(eul, &
            vec3_create(0.0_dp, 90.0_dp, 0.0_dp), 1.0e-9_dp, &
            'euler(0,90,0) round-trips exactly')

        ! ---------- mat4_inverse ----------------------------------
        ! vs mat4_inverse_rigid on a rigid transform (rot + trans)
        m4a = mat4_compose_trs(vec3_create(1.0_dp, -2.0_dp, 3.0_dp), &
                               vec3_create(25.0_dp, -40.0_dp, 70.0_dp), &
                               vec3_create(1.0_dp, 1.0_dp, 1.0_dp))
        inv_g = mat4_inverse(m4a, ok4)
        call assert_true(ok4, 'mat4_inverse rigid: ok')
        inv_r = mat4_inverse_rigid(m4a)
        call assert_real_close(mat4_maxdiff4(inv_g, inv_r), 0.0_dp, &
            1.0e-9_dp, 'mat4_inverse agrees with mat4_inverse_rigid')
        ! non-rigid: scale + shear built by hand
        m4b = mat4_mult(mat4_compose_trs( &
                vec3_create(-1.0_dp, 0.5_dp, 2.0_dp), &
                vec3_create(10.0_dp, 20.0_dp, 30.0_dp), &
                vec3_create(2.0_dp, 0.5_dp, 1.5_dp)), &
            mat4_identity())
        m4b%m(1, 2) = m4b%m(1, 2) + 0.3_dp  ! shear on the composed M
        inv_g = mat4_inverse(m4b, ok4)
        call assert_true(ok4, 'mat4_inverse scale+shear: ok')
        call assert_real_close( &
            mat4_maxdiff_id(mat4_mult(m4b, inv_g)), 0.0_dp, &
            1.0e-9_dp, 'mat4_inverse scale+shear: M * Minv == I')
        call assert_real_close( &
            mat4_maxdiff_id(mat4_mult(inv_g, m4b)), 0.0_dp, &
            1.0e-9_dp, 'mat4_inverse scale+shear: Minv * M == I')
        ! singular: zero scale axis -> det exactly 0
        m4b = mat4_scale(1.0_dp, 0.0_dp, 1.0_dp)
        inv_g = mat4_inverse(m4b, ok4)
        call assert_false(ok4, 'mat4_inverse singular: ok is false')
        call assert_real_close(mat4_maxdiff_id(inv_g), 0.0_dp, &
            0.0_dp, 'mat4_inverse singular: result is identity')
    end subroutine direct_tests

    subroutine check_mat4_roundtrip(euler_deg, label)
        type(vec3), intent(in) :: euler_deg
        character(len=*), intent(in) :: label
        type(quat) :: q
        q = quat_from_euler(euler_deg)
        call assert_quat_close(quat_from_mat4(quat_to_mat4(q)), q, &
            1.0e-12_dp, 'quat_from_mat4 round trip: ' // label)
        call assert_quat_close(quat_from_mat3(quat_to_mat3(q)), q, &
            1.0e-12_dp, 'quat_from_mat3 round trip: ' // label)
    end subroutine check_mat4_roundtrip

    subroutine check_gimbal(euler_deg, label)
        type(vec3), intent(in) :: euler_deg
        character(len=*), intent(in) :: label
        type(quat) :: q
        type(mat4) :: m
        type(vec3) :: v
        q = quat_from_euler(euler_deg)
        m = mat4_compose_trs(vec3_create(0.0_dp, 0.0_dp, 0.0_dp), &
                             euler_deg, &
                             vec3_create(1.0_dp, 1.0_dp, 1.0_dp))
        v = vec3_create(1.0_dp, 2.0_dp, 3.0_dp)
        call assert_vec3_close(quat_rotate_vec3(q, v), &
            mat4_transform_vec3(m, v, .false.), 1.0e-9_dp, &
            'gimbal ' // label // ': quat rotation == compose_trs')
    end subroutine check_gimbal

end program test_math_quat
