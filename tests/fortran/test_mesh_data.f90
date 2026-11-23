program test_mesh_data
    ! v3.0 Phase 1 (G1): indexed mesh_data builders.
    ! For every builder: documented shared vertex / triangle counts,
    ! index bounds, real UVs in [0,1], bounds from finalize, and the
    ! mesh_data_to_triangles shim reproducing the indexed data at
    ! every corner (positions from the dp shadow, UVs from md%uv).
    ! This program references module mesh_data_3d, which did not
    ! exist before Phase 1 -- it cannot compile, let alone pass,
    ! against the old soup-only code.
    use math_3d
    use mesh_3d
    use mesh_data_3d
    use geo_capsule_3d, only: build_capsule_data
    use geo_flat_3d, only: build_circle_data, build_ring_data
    use geo_extrude_3d, only: build_extrude_data
    use geo_lathe_3d, only: build_lathe_data
    use geo_poly_3d, only: build_tetrahedron_data, &
        build_octahedron_data, build_icosahedron_data, &
        build_dodecahedron_data
    use geo_torusknot_3d, only: build_torusknot_data
    use geo_tube_3d, only: build_tube_data
    use texture_3d, only: prim_uv
    use test_assert
    implicit none

    type(mesh_data) :: md
    type(Mesh) :: soup
    real(dp) :: prof(6), path(9), square(8)
    real(dp) :: puv(2)
    integer :: vi

    ! ---- mesh.f90 builders ----
    call build_cube_data(md, 2.0_dp)
    call expect_counts(md, 'cube', 24, 12)
    call check_data(md, 'cube')
    call mesh_data_free(md)

    call build_box_data(md, 1.0_dp, 2.0_dp, 3.0_dp)
    call expect_counts(md, 'box', 24, 12)
    call check_data(md, 'box')
    call mesh_data_free(md)

    call build_sphere_data(md, 1.0_dp, 16)
    call expect_counts(md, 'sphere seg=16', 219, 352)
    call check_data(md, 'sphere')
    ! Real builder UVs vs prim_uv synthesis: at ring-1 vertex i=2
    ! (theta = 2pi/16) the indexed u is (i-1)/seg = 0.0625 while
    ! prim_uv adds its +0.5 phase (0.5625) -- the builder data is the
    ! canonical [0,1] sweep, prim_uv's is a sampler-wrapped phase.
    vi = 16 + 2  ! ring 1, vertex 2
    puv = prim_uv('sphere', vec3_create(real(md%pos_dp(1, vi), dp), &
                                        real(md%pos_dp(2, vi), dp), &
                                        real(md%pos_dp(3, vi), dp)), &
                  [2.0_dp, 2.0_dp, 2.0_dp])
    call assert_true(abs(real(md%uv(1, vi), dp) - puv(1)) > 0.4_dp, &
        'sphere builder u differs from prim_uv by its 0.5 phase')
    call assert_real_close(0.0625_dp, real(md%uv(1, vi), dp), 1.0e-6_dp, &
        'sphere builder u at ring1 vertex2 == 1/16')
    call mesh_data_free(md)

    call build_cylinder_data(md, 1.0_dp, 2.0_dp, 16, .true.)
    call expect_counts(md, 'cylinder capped seg=16', 70, 64)
    call check_data(md, 'cylinder capped')
    call mesh_data_free(md)

    call build_cylinder_data(md, 1.0_dp, 2.0_dp, 16, .false.)
    call expect_counts(md, 'cylinder open seg=16', 34, 32)
    call check_data(md, 'cylinder open')
    call mesh_data_free(md)

    call build_cone_data(md, 1.0_dp, 2.0_dp, 16, .true.)
    call expect_counts(md, 'cone capped seg=16', 51, 32)
    call check_data(md, 'cone capped')
    call mesh_data_free(md)

    call build_cone_data(md, 1.0_dp, 2.0_dp, 16, .false.)
    call expect_counts(md, 'cone open seg=16', 33, 16)
    call check_data(md, 'cone open')
    call mesh_data_free(md)

    call build_plane_data(md, 2.0_dp, 3.0_dp)
    call expect_counts(md, 'plane', 8, 4)
    call check_data(md, 'plane')
    call mesh_data_free(md)

    call build_pyramid_data(md, 2.0_dp, 1.5_dp)
    call expect_counts(md, 'pyramid', 16, 6)
    call check_data(md, 'pyramid')
    call mesh_data_free(md)

    call build_torus_data(md, 2.0_dp, 0.5_dp, 24, 12)
    call expect_counts(md, 'torus (24,12)', 325, 576)
    call check_data(md, 'torus')
    call assert_true(.not. allocated(md%tan), &
        'torus tangents stay unallocated in Phase 1')
    call mesh_data_free(md)

    ! ---- geo_* builders ----
    call build_capsule_data(md, 1.0_dp, 2.0_dp, 16)
    call expect_counts(md, 'capsule seg=16', 168, 256)
    call check_data(md, 'capsule')
    call mesh_data_free(md)

    call build_circle_data(md, 2.0_dp, 16)
    call expect_counts(md, 'circle seg=16', 34, 32)
    call check_data(md, 'circle')
    call mesh_data_free(md)

    call build_ring_data(md, 1.0_dp, 2.0_dp, 16)
    call expect_counts(md, 'ring seg=16', 64, 64)
    call check_data(md, 'ring')
    call mesh_data_free(md)

    square = [0.0_dp, 0.0_dp, 1.0_dp, 0.0_dp, &
              1.0_dp, 1.0_dp, 0.0_dp, 1.0_dp]
    call build_extrude_data(md, 1.0_dp, square, 4)
    call expect_counts(md, 'extrude square', 24, 12)
    call check_data(md, 'extrude')
    call mesh_data_free(md)

    prof = [0.5_dp, 0.0_dp, 1.0_dp, 0.5_dp, 0.5_dp, 1.0_dp]
    call build_lathe_data(md, 8, prof, 3)
    call expect_counts(md, 'lathe 3pt seg=8', 36, 32)
    call check_data(md, 'lathe')
    call mesh_data_free(md)

    call build_tetrahedron_data(md, 1.0_dp)
    call expect_counts(md, 'tetrahedron', 12, 4, shared=.false.)
    call check_data(md, 'tetrahedron')
    call mesh_data_free(md)

    call build_octahedron_data(md, 1.0_dp)
    call expect_counts(md, 'octahedron', 24, 8, shared=.false.)
    call check_data(md, 'octahedron')
    call mesh_data_free(md)

    call build_icosahedron_data(md, 1.0_dp)
    call expect_counts(md, 'icosahedron', 60, 20, shared=.false.)
    call check_data(md, 'icosahedron')
    call mesh_data_free(md)

    call build_dodecahedron_data(md, 1.0_dp)
    call expect_counts(md, 'dodecahedron', 108, 36, shared=.false.)
    call check_data(md, 'dodecahedron')
    call mesh_data_free(md)

    call build_torusknot_data(md, 1.0_dp, 0.3_dp, 16, 8)
    call expect_counts(md, 'torusknot (16,8)', 153, 256)
    call check_data(md, 'torusknot')
    call mesh_data_free(md)

    path = [0.0_dp, 0.0_dp, 0.0_dp, 1.0_dp, 0.0_dp, 0.0_dp, &
            1.0_dp, 1.0_dp, 0.0_dp]
    call build_tube_data(md, 0.25_dp, 8, path, 3)
    call expect_counts(md, 'tube 3pt seg=8', 47, 48)
    call check_data(md, 'tube')
    call mesh_data_free(md)

    ! ---- finalize: smooth normals computed from idx when absent ----
    call mesh_data_alloc(md, 4, 2)
    ! Rebuild by hand without normals: free the alloc'd normal arrays.
    deallocate(md%nrm, md%nrm_dp)
    md%pos(:, 1) = [0.0, 0.0, 0.0]
    md%pos(:, 2) = [1.0, 0.0, 0.0]
    md%pos(:, 3) = [1.0, 1.0, 0.0]
    md%pos(:, 4) = [0.0, 1.0, 0.0]
    md%pos_dp(:, 1) = [0.0_dp, 0.0_dp, 0.0_dp]
    md%pos_dp(:, 2) = [1.0_dp, 0.0_dp, 0.0_dp]
    md%pos_dp(:, 3) = [1.0_dp, 1.0_dp, 0.0_dp]
    md%pos_dp(:, 4) = [0.0_dp, 1.0_dp, 0.0_dp]
    md%idx(:, 1) = [1, 2, 3]
    md%idx(:, 2) = [1, 3, 4]
    call mesh_data_finalize(md)
    call assert_true(allocated(md%nrm), &
        'finalize allocates computed normals')
    call assert_real_close(1.0_dp, real(md%nrm(3, 1), dp), 1.0e-6_dp, &
        'finalize computed normal is +Z')
    call assert_real_close(1.0_dp, real(md%bmax(1), dp), 1.0e-6_dp, &
        'finalize bounds bmax x == 1')
    call assert_real_close(0.0_dp, real(md%bmin(3), dp), 1.0e-6_dp, &
        'finalize bounds bmin z == 0')
    call mesh_data_free(md)
    call assert_true(md%n_verts == 0 .and. .not. allocated(md%pos), &
        'mesh_data_free resets the mesh')

    call test_summary()

contains

    subroutine expect_counts(md, label, nv, nt, shared)
        type(mesh_data), intent(in) :: md
        character(len=*), intent(in) :: label
        integer, intent(in) :: nv, nt
        logical, intent(in), optional :: shared
        logical :: strict
        strict = .true.
        if (present(shared)) strict = shared
        call assert_int_eq(nv, md%n_verts, label//' n_verts')
        call assert_int_eq(nt, md%n_tris, label//' n_tris')
        if (strict) then
            call assert_true(md%n_verts < 3 * md%n_tris, &
                label//' shares vertices (verts < 3*tris soup count)')
        else
            ! Flat-shaded split solids: indexed, but every face owns
            ! its vertices, so n_verts == 3*n_tris exactly.
            call assert_true(md%n_verts <= 3 * md%n_tris, &
                label//' is indexed (verts <= 3*tris soup count)')
        end if
    end subroutine expect_counts

    ! Generic invariants + shim fidelity for one built mesh_data.
    subroutine check_data(md, label)
        type(mesh_data), intent(in) :: md
        character(len=*), intent(in) :: label
        integer :: t, k, v
        logical :: ok

        ok = all(md%idx >= 1) .and. all(md%idx <= md%n_verts)
        call assert_true(ok, label//' indices within [1, n_verts]')
        call assert_true(allocated(md%uv), label//' uv allocated')
        ok = all(md%uv >= 0.0) .and. all(md%uv <= 1.0)
        call assert_true(ok, label//' uv within [0,1]')
        ok = allocated(md%nrm)
        call assert_true(ok, label//' normals present after finalize')
        do k = 1, 3
            call assert_real_close(real(minval(md%pos(k, :)), dp), &
                real(md%bmin(k), dp), 1.0e-6_dp, &
                label//' bmin matches pos')
            call assert_real_close(real(maxval(md%pos(k, :)), dp), &
                real(md%bmax(k), dp), 1.0e-6_dp, &
                label//' bmax matches pos')
        end do

        call mesh_data_to_triangles(md, soup)
        call assert_int_eq(md%n_tris, soup%num_triangles, &
            label//' shim triangle count == n_tris')
        ok = .true.
        do t = 1, md%n_tris
            do k = 1, 3
                v = md%idx(k, t)
                if (abs(soup%triangles(t)%v(k)%x - md%pos_dp(1, v)) &
                        > 1.0e-12_dp) ok = .false.
                if (abs(soup%triangles(t)%v(k)%y - md%pos_dp(2, v)) &
                        > 1.0e-12_dp) ok = .false.
                if (abs(soup%triangles(t)%v(k)%z - md%pos_dp(3, v)) &
                        > 1.0e-12_dp) ok = .false.
                if (abs(soup%triangles(t)%uv(1, k) - &
                        real(md%uv(1, v), dp)) > 1.0e-12_dp) ok = .false.
                if (abs(soup%triangles(t)%uv(2, k) - &
                        real(md%uv(2, v), dp)) > 1.0e-12_dp) ok = .false.
            end do
        end do
        call assert_true(ok, &
            label//' shim corners match indexed pos + uv at idx')
        call free_mesh(soup)
    end subroutine check_data

end program test_mesh_data
