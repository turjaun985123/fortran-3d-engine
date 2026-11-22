program test_instancing
    use math_3d
    use mesh_3d
    use instancing_3d
    use test_assert
    implicit none

    type(Mesh) :: base, built
    type(InstanceSet) :: set, empty_set
    type(mat4) :: third
    type(vec3) :: want
    integer :: i, k
    logical :: all_exact

    ! ---- count bookkeeping on a fresh set ----
    call create_cube(base, 2.0_dp)
    call assert_int_eq(12, base%num_triangles, 'cube base has 12 triangles')

    call instancing_init(set, base)
    call assert_int_eq(0, instancing_count(set), 'count is 0 after init')
    call assert_int_eq(12, set%base%num_triangles, &
        'init keeps the one base mesh (12 tris, not expanded)')

    call instancing_add(set, mat4_identity())
    call assert_int_eq(1, instancing_count(set), 'count is 1 after first add')
    call instancing_add(set, mat4_translation(5.0_dp, -2.0_dp, 3.0_dp))
    call assert_int_eq(2, instancing_count(set), 'count is 2 after second add')
    third = mat4_compose_trs(vec3_create(-4.0_dp, 1.0_dp, 2.0_dp), &
                             vec3_create(0.0_dp, 45.0_dp, 0.0_dp), &
                             vec3_create(2.0_dp, 2.0_dp, 2.0_dp))
    call instancing_add(set, third)
    call assert_int_eq(3, instancing_count(set), 'count is 3 after third add')
    call assert_int_eq(3, size(set%transforms), &
        'transforms array holds exactly count entries (no geometry copies)')

    ! ---- build: 3 instances x 12 tris = 36 ----
    call instancing_build_mesh(set, built)
    call assert_int_eq(36, built%num_triangles, &
        'built mesh has count * base tris (3 * 12 = 36)')
    call assert_true(allocated(built%triangles), 'built mesh is allocated')

    ! ---- instance 1 (identity, tris 1..12) reproduces base exactly ----
    all_exact = .true.
    do i = 1, 12
        do k = 1, 3
            if (abs(built%triangles(i)%v(k)%x - base%triangles(i)%v(k)%x) > 0.0_dp .or. &
                abs(built%triangles(i)%v(k)%y - base%triangles(i)%v(k)%y) > 0.0_dp .or. &
                abs(built%triangles(i)%v(k)%z - base%triangles(i)%v(k)%z) > 0.0_dp) &
                all_exact = .false.
        end do
    end do
    call assert_true(all_exact, &
        'identity instance reproduces every base vertex exactly')

    ! ---- instance 2 (translation, tris 13..24) offset exactly ----
    all_exact = .true.
    do i = 1, 12
        do k = 1, 3
            want = vec3_create(base%triangles(i)%v(k)%x + 5.0_dp, &
                               base%triangles(i)%v(k)%y - 2.0_dp, &
                               base%triangles(i)%v(k)%z + 3.0_dp)
            if (abs(built%triangles(12 + i)%v(k)%x - want%x) > 0.0_dp .or. &
                abs(built%triangles(12 + i)%v(k)%y - want%y) > 0.0_dp .or. &
                abs(built%triangles(12 + i)%v(k)%z - want%z) > 0.0_dp) &
                all_exact = .false.
        end do
    end do
    call assert_true(all_exact, &
        'translated instance vertices are offset by exactly (5,-2,3)')

    ! ---- instance 3 (TRS, tris 25..36) is placed by its transform ----
    want = mat4_transform_vec3(third, base%triangles(1)%v(1), .true.)
    call assert_vec3_close(want, built%triangles(25)%v(1), 0.0_dp, &
        'third instance tri 1 vertex 1 equals mat4 * base vertex exactly')
    call assert_true(abs(built%triangles(25)%v(1)%x - base%triangles(1)%v(1)%x) > 0.0_dp .or. &
                     abs(built%triangles(25)%v(1)%y - base%triangles(1)%v(1)%y) > 0.0_dp .or. &
                     abs(built%triangles(25)%v(1)%z - base%triangles(1)%v(1)%z) > 0.0_dp, &
        'third instance is distinct from the base placement')

    ! ---- empty set builds an empty mesh (and resets a filled target) ----
    call instancing_init(empty_set, base)
    call assert_int_eq(0, instancing_count(empty_set), 'empty set count is 0')
    call instancing_build_mesh(empty_set, built)
    call assert_int_eq(0, built%num_triangles, &
        'empty set builds an empty mesh (0 triangles)')

    ! ---- free resets the set ----
    call instancing_free(set)
    call assert_int_eq(0, instancing_count(set), 'count is 0 after free')
    call assert_false(allocated(set%transforms), &
        'transforms are deallocated after free')

    call instancing_free(empty_set)
    call free_mesh(base)
    call free_mesh(built)

    call test_summary()
end program test_instancing
