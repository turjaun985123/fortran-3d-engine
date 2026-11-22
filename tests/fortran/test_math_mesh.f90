program test_math_mesh
    use math_3d
    use mesh_3d
    use test_assert
    implicit none

    type(vec3) :: a, b, p, got, want
    type(mat4) :: ident, trans, m1, m2
    type(Mesh) :: msh, other_m, combined_m
    integer :: rgb(3)

    ! ---- vec3: dot / cross / normalize ----
    a = vec3_create(1.0_dp, 2.0_dp, 3.0_dp)
    b = vec3_create(4.0_dp, 5.0_dp, 6.0_dp)
    call assert_real_close(32.0_dp, vec3_dot(a, b), 1.0e-12_dp, &
        'vec3_dot (1,2,3).(4,5,6)==32')
    call assert_real_close(0.0_dp, vec3_dot(vec3_create(1.0_dp, 0.0_dp, 0.0_dp), &
        vec3_create(0.0_dp, 1.0_dp, 0.0_dp)), 1.0e-12_dp, 'vec3_dot orthogonal==0')

    call assert_vec3_close(vec3_create(0.0_dp, 0.0_dp, 1.0_dp), &
        vec3_cross(vec3_create(1.0_dp, 0.0_dp, 0.0_dp), &
                   vec3_create(0.0_dp, 1.0_dp, 0.0_dp)), &
        1.0e-12_dp, 'vec3_cross X x Y == Z')
    call assert_vec3_close(vec3_create(-3.0_dp, 6.0_dp, -3.0_dp), &
        vec3_cross(vec3_create(2.0_dp, 3.0_dp, 4.0_dp), &
                   vec3_create(5.0_dp, 6.0_dp, 7.0_dp)), &
        1.0e-12_dp, 'vec3_cross (2,3,4)x(5,6,7)==(-3,6,-3)')

    call assert_vec3_close(vec3_create(0.6_dp, 0.0_dp, 0.8_dp), &
        vec3_normalize(vec3_create(3.0_dp, 0.0_dp, 4.0_dp)), &
        1.0e-12_dp, 'vec3_normalize (3,0,4)==(0.6,0,0.8)')
    call assert_real_close(1.0_dp, &
        vec3_norm(vec3_normalize(vec3_create(1.0_dp, -2.0_dp, 2.0_dp))), &
        1.0e-12_dp, 'vec3_normalize result has unit norm')
    call assert_real_close(5.0_dp, vec3_norm(vec3_create(3.0_dp, 0.0_dp, 4.0_dp)), &
        1.0e-12_dp, 'vec3_norm (3,0,4)==5')

    ! ---- mat4: identity / multiply / translation ----
    ident = mat4_identity()
    p = vec3_create(1.5_dp, -2.5_dp, 3.5_dp)
    call assert_vec3_close(p, mat4_transform_vec3(ident, p, .true.), &
        1.0e-12_dp, 'mat4_identity leaves a point unchanged')

    trans = mat4_translation(2.0_dp, 3.0_dp, 4.0_dp)
    call assert_vec3_close(vec3_create(3.0_dp, 4.0_dp, 5.0_dp), &
        mat4_transform_vec3(trans, vec3_create(1.0_dp, 1.0_dp, 1.0_dp), .true.), &
        1.0e-12_dp, 'mat4_translation moves point (1,1,1) to (3,4,5)')
    call assert_vec3_close(vec3_create(1.0_dp, 1.0_dp, 1.0_dp), &
        mat4_transform_vec3(trans, vec3_create(1.0_dp, 1.0_dp, 1.0_dp), .false.), &
        1.0e-12_dp, 'mat4_translation leaves a direction unchanged')

    m1 = mat4_mult(ident, trans)
    call assert_vec3_close(vec3_create(3.0_dp, 4.0_dp, 5.0_dp), &
        mat4_transform_vec3(m1, vec3_create(1.0_dp, 1.0_dp, 1.0_dp), .true.), &
        1.0e-12_dp, 'mat4_mult identity*T == T on a point')
    m2 = mat4_mult(mat4_translation(1.0_dp, 0.0_dp, 0.0_dp), &
                   mat4_translation(0.0_dp, 2.0_dp, 0.0_dp))
    call assert_vec3_close(vec3_create(1.0_dp, 2.0_dp, 0.0_dp), &
        mat4_transform_vec3(m2, vec3_create(0.0_dp, 0.0_dp, 0.0_dp), .true.), &
        1.0e-12_dp, 'mat4_mult translations compose additively')

    ! ---- mat4_compose_trs: rot (20,35,0) == Ry(35deg) * Rx(20deg) ----
    p = vec3_create(0.7_dp, -1.2_dp, 2.3_dp)
    m1 = mat4_compose_trs(vec3_create(0.0_dp, 0.0_dp, 0.0_dp), &
                          vec3_create(20.0_dp, 35.0_dp, 0.0_dp), &
                          vec3_create(1.0_dp, 1.0_dp, 1.0_dp))
    m2 = mat4_mult(mat4_rotate_y(deg2rad(35.0_dp)), &
                   mat4_rotate_x(deg2rad(20.0_dp)))
    got = mat4_transform_vec3(m1, p, .true.)
    want = mat4_transform_vec3(m2, p, .true.)
    call assert_vec3_close(want, got, 1.0e-9_dp, &
        'compose_trs rot(20,35,0) == Ry(35)*Rx(20) on a point')

    ! ---- mat4_axis_angle: Y, 90deg maps +X to -Z ----
    m1 = mat4_axis_angle(vec3_create(0.0_dp, 1.0_dp, 0.0_dp), 90.0_dp)
    got = mat4_transform_vec3(m1, vec3_create(1.0_dp, 0.0_dp, 0.0_dp), .true.)
    call assert_vec3_close(vec3_create(0.0_dp, 0.0_dp, -1.0_dp), got, &
        1.0e-9_dp, 'axis_angle Y 90deg maps +X to -Z')

    ! ---- cube: 12 tris, palette colour of tri 1 ----
    call create_cube(msh, 2.0_dp)
    call assert_int_eq(12, msh%num_triangles, 'cube has 12 triangles')
    call assert_int_eq(220, msh%triangles(1)%color(1), 'cube tri 1 colour R==220')
    call assert_int_eq(60, msh%triangles(1)%color(2), 'cube tri 1 colour G==60')
    call assert_int_eq(60, msh%triangles(1)%color(3), 'cube tri 1 colour B==60')
    call check_normals(msh, 'cube')

    ! ---- sphere: segments=16 -> 352 tris ----
    call create_sphere(msh, 1.0_dp, 16)
    call assert_int_eq(352, msh%num_triangles, 'sphere segments=16 has 352 triangles')
    call check_normals(msh, 'sphere')

    ! ---- cylinder: capped, seg 16 -> 64 tris ----
    call create_cylinder(msh, 1.0_dp, 2.0_dp, 16, .true.)
    call assert_int_eq(64, msh%num_triangles, 'cylinder capped seg=16 has 64 triangles')
    call check_normals(msh, 'cylinder')

    ! ---- cone: capped, seg 16 -> 32 tris ----
    call create_cone(msh, 1.0_dp, 2.0_dp, 16, .true.)
    call assert_int_eq(32, msh%num_triangles, 'cone capped seg=16 has 32 triangles')
    call check_normals(msh, 'cone')

    ! ---- plane: 4 tris (double-sided, D1/WB-INV-PLANE) ----
    call create_plane(msh, 2.0_dp, 3.0_dp)
    call assert_int_eq(4, msh%num_triangles, 'plane has 4 triangles')
    call check_normals(msh, 'plane')

    ! ---- pyramid: 6 tris ----
    call create_pyramid(msh, 2.0_dp, 1.5_dp)
    call assert_int_eq(6, msh%num_triangles, 'pyramid has 6 triangles')
    call check_normals(msh, 'pyramid')

    ! ---- torus: (24,12) -> 576 tris ----
    call create_torus(msh, 2.0_dp, 0.5_dp, 24, 12)
    call assert_int_eq(576, msh%num_triangles, 'torus (24,12) has 576 triangles')
    call check_normals(msh, 'torus')

    ! ---- box: 12 tris ----
    call create_box(msh, 1.0_dp, 2.0_dp, 3.0_dp)
    call assert_int_eq(12, msh%num_triangles, 'box has 12 triangles')
    call check_normals(msh, 'box')

    ! ---- mesh_append doubles the triangle count ----
    call create_cube(msh, 1.0_dp)
    call create_cube(other_m, 1.0_dp)
    call mesh_append(msh, other_m)
    call assert_int_eq(24, msh%num_triangles, 'mesh_append cube+cube == 24 triangles')
    call assert_true(allocated(msh%triangles), 'mesh_append result is allocated')

    ! ---- mesh_add_transformed translates vertices ----
    call create_cube(other_m, 2.0_dp)
    combined_m%num_triangles = 0
    rgb = [0, 0, 0]
    call mesh_add_transformed(combined_m, other_m, &
        mat4_translation(5.0_dp, -2.0_dp, 3.0_dp), .false., rgb, 0)
    call assert_int_eq(other_m%num_triangles, combined_m%num_triangles, &
        'mesh_add_transformed keeps the triangle count')
    want = vec3_create(other_m%triangles(1)%v(1)%x + 5.0_dp, &
                       other_m%triangles(1)%v(1)%y - 2.0_dp, &
                       other_m%triangles(1)%v(1)%z + 3.0_dp)
    call assert_vec3_close(want, combined_m%triangles(1)%v(1), 1.0e-12_dp, &
        'mesh_add_transformed translates tri 1 vertex 1')
    want = vec3_create(other_m%triangles(12)%v(3)%x + 5.0_dp, &
                       other_m%triangles(12)%v(3)%y - 2.0_dp, &
                       other_m%triangles(12)%v(3)%z + 3.0_dp)
    call assert_vec3_close(want, combined_m%triangles(12)%v(3), 1.0e-12_dp, &
        'mesh_add_transformed translates tri 12 vertex 3')

    call free_mesh(msh)
    call free_mesh(other_m)
    call free_mesh(combined_m)

    call test_summary()

contains

    subroutine check_normals(m, builder)
        type(Mesh), intent(in) :: m
        character(len=*), intent(in) :: builder
        integer :: idx(3), k
        idx = [1, max(1, m%num_triangles / 2), m%num_triangles]
        do k = 1, 3
            call assert_real_close(1.0_dp, vec3_norm(m%triangles(idx(k))%normal), &
                1.0e-6_dp, builder//' builder normal is unit length')
        end do
    end subroutine check_normals

end program test_math_mesh
