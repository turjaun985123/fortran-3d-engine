program test_smooth_normals
    ! P1 smooth shading: per-vertex normals (vn) and the smooth flag.
    !   - curved builders (sphere, cylinder/cone sides, torus) set
    !     smooth=.true. with analytic, unit-length per-vertex normals;
    !   - flat builders (cube, cylinder/cone caps) keep smooth=.false.
    !     and vn(k) == face normal for all k;
    !   - mesh_add_transformed rotates vn as directions and preserves
    !     the smooth flag.
    use math_3d
    use mesh_3d
    use test_assert
    implicit none

    type(Mesh) :: msh, src_m, dst_m
    type(mat4) :: rot_y90
    type(vec3) :: expected, centre, radial
    integer :: i, k, rgb(3)
    integer :: n_side, n_cap, n_base_checked
    real(dp) :: theta, rl, area2
    real(dp), parameter :: radius = 1.0_dp, height = 2.0_dp, hh = 1.0_dp
    real(dp), parameter :: torus_r = 2.0_dp, torus_tube = 0.5_dp

    ! ---- sphere: every tri smooth, vn unit and parallel to position ----
    call create_sphere(msh, 1.5_dp, 16)
    do i = 1, msh%num_triangles
        ! Skip degenerate triangles (zero area): none are expected for
        ! this construction, but the parallel check is meaningless there.
        area2 = vec3_norm(vec3_cross( &
            vec3_sub(msh%triangles(i)%v(2), msh%triangles(i)%v(1)), &
            vec3_sub(msh%triangles(i)%v(3), msh%triangles(i)%v(1))))
        if (area2 <= 1.0e-12_dp) cycle
        call assert_true(msh%triangles(i)%smooth, 'sphere tri is smooth')
        do k = 1, 3
            call assert_real_close(1.0_dp, vec3_norm(msh%triangles(i)%vn(k)), &
                1.0e-9_dp, 'sphere vn is unit length')
            call assert_true(vec3_dot(vec3_normalize(msh%triangles(i)%v(k)), &
                msh%triangles(i)%vn(k)) > 1.0_dp - 1.0e-9_dp, &
                'sphere vn is parallel to its vertex position')
        end do
    end do

    ! ---- cube: every tri flat, vn(k) == face normal exactly ----
    call create_cube(msh, 2.0_dp)
    do i = 1, msh%num_triangles
        call assert_false(msh%triangles(i)%smooth, 'cube tri is not smooth')
        do k = 1, 3
            call assert_true( &
                msh%triangles(i)%vn(k)%x == msh%triangles(i)%normal%x .and. &
                msh%triangles(i)%vn(k)%y == msh%triangles(i)%normal%y .and. &
                msh%triangles(i)%vn(k)%z == msh%triangles(i)%normal%z, &
                'cube vn(k) == face normal')
        end do
    end do

    ! ---- cylinder (capped): side smooth + radial, caps flat ----
    ! Cap triangles are identified by their +/-Y face normal (see
    ! is_cap_tri below); every side vertex lies on the radius.
    call create_cylinder(msh, radius, height, 16, .true.)
    n_side = 0
    n_cap = 0
    do i = 1, msh%num_triangles
        if (is_cap_tri(msh%triangles(i))) then
            n_cap = n_cap + 1
            call assert_false(msh%triangles(i)%smooth, &
                'cylinder cap tri is not smooth')
            do k = 1, 3
                call assert_true( &
                    msh%triangles(i)%vn(k)%x == msh%triangles(i)%normal%x .and. &
                    msh%triangles(i)%vn(k)%y == msh%triangles(i)%normal%y .and. &
                    msh%triangles(i)%vn(k)%z == msh%triangles(i)%normal%z, &
                    'cylinder cap vn(k) == face normal')
            end do
        else
            n_side = n_side + 1
            call assert_true(msh%triangles(i)%smooth, &
                'cylinder side tri is smooth')
            do k = 1, 3
                call assert_real_close(0.0_dp, msh%triangles(i)%vn(k)%y, &
                    1.0e-9_dp, 'cylinder side vn has y == 0')
                rl = sqrt(msh%triangles(i)%v(k)%x**2 + &
                          msh%triangles(i)%v(k)%z**2)
                radial = vec3_create(msh%triangles(i)%v(k)%x / rl, 0.0_dp, &
                                     msh%triangles(i)%v(k)%z / rl)
                call assert_real_close(1.0_dp, &
                    vec3_dot(radial, msh%triangles(i)%vn(k)), 1.0e-9_dp, &
                    'cylinder side vn is radial at its vertex')
            end do
        end if
    end do
    call assert_int_eq(32, n_side, 'cylinder capped seg=16 has 32 side tris')
    call assert_int_eq(32, n_cap, 'cylinder capped seg=16 has 32 cap tris')

    ! ---- cone (capped): side smooth, base vn == slant normal ----
    ! Side triangles are [base1, apex, base2]; only the base vertices
    ! carry the azimuth slant normal (the apex carries an average).
    call create_cone(msh, radius, height, 16, .true.)
    n_side = 0
    n_cap = 0
    n_base_checked = 0
    do i = 1, msh%num_triangles
        if (is_cap_tri(msh%triangles(i))) then
            n_cap = n_cap + 1
            call assert_false(msh%triangles(i)%smooth, &
                'cone cap tri is not smooth')
        else
            n_side = n_side + 1
            call assert_true(msh%triangles(i)%smooth, &
                'cone side tri is smooth')
            do k = 1, 3
                if (abs(msh%triangles(i)%v(k)%y + hh) > 1.0e-12_dp) cycle
                rl = sqrt(msh%triangles(i)%v(k)%x**2 + &
                          msh%triangles(i)%v(k)%z**2)
                if (abs(rl - radius) > 1.0e-9_dp) cycle
                n_base_checked = n_base_checked + 1
                theta = atan2(msh%triangles(i)%v(k)%z, &
                              msh%triangles(i)%v(k)%x)
                expected = vec3_normalize(vec3_create( &
                    height * cos(theta), radius, height * sin(theta)))
                call assert_vec3_close(expected, msh%triangles(i)%vn(k), &
                    1.0e-9_dp, &
                    'cone base vn == normalize((h cos, r, h sin))')
            end do
        end if
    end do
    call assert_int_eq(16, n_side, 'cone capped seg=16 has 16 side tris')
    call assert_int_eq(16, n_cap, 'cone capped seg=16 has 16 cap tris')
    call assert_int_eq(32, n_base_checked, &
        'cone side tris have 32 base vertices checked')

    ! ---- torus: all smooth, vn == normalize(v - tube centre) ----
    ! The tube centre for a vertex at azimuth theta (recomputed from
    ! the vertex itself, as the builder does) is
    ! (R cos theta, 0, R sin theta).
    call create_torus(msh, torus_r, torus_tube, 12, 8)
    do i = 1, msh%num_triangles
        call assert_true(msh%triangles(i)%smooth, 'torus tri is smooth')
        do k = 1, 3
            theta = atan2(msh%triangles(i)%v(k)%z, &
                          msh%triangles(i)%v(k)%x)
            centre = vec3_create(torus_r * cos(theta), 0.0_dp, &
                                 torus_r * sin(theta))
            expected = vec3_normalize(vec3_sub(msh%triangles(i)%v(k), centre))
            call assert_vec3_close(expected, msh%triangles(i)%vn(k), &
                1.0e-9_dp, 'torus vn == normalize(v - tube centre)')
        end do
    end do

    ! ---- mesh_add_transformed: 90 deg Y rotation of a sphere ----
    call create_sphere(src_m, 1.25_dp, 8)
    dst_m%num_triangles = 0
    rgb = [0, 0, 0]
    rot_y90 = mat4_rotate_y(PI * 0.5_dp)
    call mesh_add_transformed(dst_m, src_m, rot_y90, .false., rgb, 0)
    call assert_int_eq(src_m%num_triangles, dst_m%num_triangles, &
        'mesh_add_transformed keeps the sphere triangle count')
    do i = 1, dst_m%num_triangles
        call assert_true(dst_m%triangles(i)%smooth .eqv. &
            src_m%triangles(i)%smooth, &
            'mesh_add_transformed preserves the smooth flag')
        do k = 1, 3
            expected = vec3_normalize(dst_m%triangles(i)%v(k))
            call assert_vec3_close(expected, dst_m%triangles(i)%vn(k), &
                1.0e-9_dp, &
                'rotated sphere vn == normalize(transformed v)')
        end do
    end do

    call free_mesh(msh)
    call free_mesh(src_m)
    call free_mesh(dst_m)
    call test_summary()

contains

    ! A capped cylinder/cone cap triangle is the one whose face
    ! normal is exactly +/-Y; side normals never are (cylinder sides
    ! are horizontal, cone sides are slanted).  (Vertex position alone
    ! cannot tell them apart: the cone apex also sits on the axis.)
    logical function is_cap_tri(tri)
        type(Triangle), intent(in) :: tri
        is_cap_tri = abs(tri%normal%x) < 1.0e-12_dp .and. &
                     abs(tri%normal%z) < 1.0e-12_dp .and. &
                     abs(abs(tri%normal%y) - 1.0_dp) < 1.0e-12_dp
    end function is_cap_tri

end program test_smooth_normals
