program test_geo_extrude
    use math_3d
    use mesh_3d
    use geo_extrude_3d
    use test_assert
    implicit none

    type(Mesh) :: msh, cw_m
    real(dp) :: square_ccw(8), square_cw(8), pentagon(10)
    real(dp), parameter :: depth = 2.0_dp
    integer :: n_top, n_bot, n_side

    ! CCW square in the shape plane: (0,0) (1,0) (1,1) (0,1).
    square_ccw = [0.0_dp, 0.0_dp,  1.0_dp, 0.0_dp, &
                  1.0_dp, 1.0_dp,  0.0_dp, 1.0_dp]
    ! Same square, opposite (CW) winding.
    square_cw = [0.0_dp, 0.0_dp,  0.0_dp, 1.0_dp, &
                 1.0_dp, 1.0_dp,  1.0_dp, 0.0_dp]
    ! CCW convex pentagon.
    pentagon = [0.0_dp, 0.0_dp,  3.0_dp, 0.0_dp,  4.0_dp, 2.0_dp, &
                2.0_dp, 4.0_dp,  0.0_dp, 2.0_dp]

    ! ---- square: 4*npts-4 = 12 tris ----
    call create_extrude(msh, depth, square_ccw, 4)
    call assert_int_eq(12, msh%num_triangles, &
        'extrude square (4 pts) has 12 triangles')
    call check_ys(msh, depth, 'square')
    call classify(msh, depth, n_top, n_bot, n_side)
    call assert_int_eq(2, n_top, 'square has 2 top-cap triangles')
    call assert_int_eq(2, n_bot, 'square has 2 bottom-cap triangles')
    call assert_int_eq(8, n_side, 'square has 8 side triangles')

    ! ---- pentagon: 4*npts-4 = 16 tris ----
    call create_extrude(msh, depth, pentagon, 5)
    call assert_int_eq(16, msh%num_triangles, &
        'extrude pentagon (5 pts) has 16 triangles')
    call check_ys(msh, depth, 'pentagon')
    call classify(msh, depth, n_top, n_bot, n_side)
    call assert_int_eq(3, n_top, 'pentagon has 3 top-cap triangles')
    call assert_int_eq(3, n_bot, 'pentagon has 3 bottom-cap triangles')
    call assert_int_eq(10, n_side, 'pentagon has 10 side triangles')

    ! ---- both windings: identical counts, outward caps ----
    call create_extrude(msh, depth, square_ccw, 4)
    call create_extrude(cw_m, depth, square_cw, 4)
    call assert_int_eq(msh%num_triangles, cw_m%num_triangles, &
        'CW and CCW squares give identical triangle counts')
    call classify(cw_m, depth, n_top, n_bot, n_side)
    call assert_int_eq(2, n_top, 'CW square has 2 top-cap triangles')
    call assert_int_eq(2, n_bot, 'CW square has 2 bottom-cap triangles')
    call assert_int_eq(8, n_side, 'CW square has 8 side triangles')
    call check_ys(cw_m, depth, 'CW square')

    ! ---- npts < 3: empty mesh ----
    call create_extrude(msh, depth, square_ccw, 2)
    call assert_int_eq(0, msh%num_triangles, &
        'extrude with npts=2 is an empty mesh')

    call free_mesh(msh)
    call free_mesh(cw_m)

    call test_summary()

contains

    ! Every vertex must sit on the ground plane or the top plane.
    subroutine check_ys(m, d, label)
        type(Mesh), intent(in) :: m
        real(dp), intent(in) :: d
        character(len=*), intent(in) :: label
        integer :: i, k
        logical :: ok
        ok = .true.
        do i = 1, m%num_triangles
            do k = 1, 3
                if (abs(m%triangles(i)%v(k)%y) > 1.0e-12_dp .and. &
                    abs(m%triangles(i)%v(k)%y - d) > 1.0e-12_dp) ok = .false.
            end do
        end do
        call assert_true(ok, label//' all verts have y in {0, depth}')
    end subroutine check_ys

    ! Classify by vertex heights and assert the outward normals:
    ! all-top tris face +Y, all-bottom tris face -Y, mixed (side)
    ! tris have horizontal normals (ny approx 0).
    subroutine classify(m, d, n_top_out, n_bot_out, n_side_out)
        type(Mesh), intent(in) :: m
        real(dp), intent(in) :: d
        integer, intent(out) :: n_top_out, n_bot_out, n_side_out
        integer :: i
        logical :: all_top, all_bot
        n_top_out = 0
        n_bot_out = 0
        n_side_out = 0
        do i = 1, m%num_triangles
            all_top = all(abs(m%triangles(i)%v(:)%y - d) <= 1.0e-12_dp)
            all_bot = all(abs(m%triangles(i)%v(:)%y) <= 1.0e-12_dp)
            if (all_top) then
                n_top_out = n_top_out + 1
                call assert_vec3_close( &
                    vec3_create(0.0_dp, 1.0_dp, 0.0_dp), &
                    m%triangles(i)%normal, 1.0e-9_dp, &
                    'top-cap normal is +Y')
            else if (all_bot) then
                n_bot_out = n_bot_out + 1
                call assert_vec3_close( &
                    vec3_create(0.0_dp, -1.0_dp, 0.0_dp), &
                    m%triangles(i)%normal, 1.0e-9_dp, &
                    'bottom-cap normal is -Y')
            else
                n_side_out = n_side_out + 1
                call assert_real_close(0.0_dp, m%triangles(i)%normal%y, &
                    1.0e-9_dp, 'side normal is horizontal (ny==0)')
                call assert_real_close(1.0_dp, &
                    vec3_norm(m%triangles(i)%normal), 1.0e-9_dp, &
                    'side normal is unit length')
            end if
        end do
    end subroutine classify

end program test_geo_extrude
