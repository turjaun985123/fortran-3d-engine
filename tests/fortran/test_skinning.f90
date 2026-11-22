program test_skinning
    use math_3d
    use mesh_3d
    use skinning_3d
    use test_assert
    implicit none

    type(Mesh) :: cube, out, tri, tri_out, sph, sph_out
    type(vec3) :: pivot, rotz90, expect, mp, p_orig
    type(mat4) :: bone
    real(dp) :: w, eq_maxerr
    integer :: si, sk, eq_count

    ! ================= morph: factor-0 exact identity =================
    call create_cube(cube, 2.0_dp)

    call morph_apply(cube, 'bulge', 0.0_dp, out)
    call assert_true(all_vertices_exact(cube, out), &
        'morph bulge factor 0 is an exact identity on a cube')
    call morph_apply(cube, 'taper', 0.0_dp, out)
    call assert_true(all_vertices_exact(cube, out), &
        'morph taper factor 0 is an exact identity on a cube')
    call morph_apply(cube, 'squash', 0.0_dp, out)
    call assert_true(all_vertices_exact(cube, out), &
        'morph squash factor 0 is an exact identity on a cube')

    ! ================= morph: unknown kind copies unchanged ==========
    call morph_apply(cube, 'wobble', 1.5_dp, out)
    call assert_true(all_vertices_exact(cube, out), &
        'morph unknown kind copies the mesh unchanged')

    ! ================= morph: bulge ==================================
    ! bulge: barrel profile — x/z scale s = 1 + factor*0.5*(1 - q^2), q = (y - cy)/halfh, strongest at the middle height, poles unchanged
    ! Triangle (0,0,0),(3,0,0),(0,3,0): centroid (1,1,0), halfh = 2.
    ! Vertices 1 and 2 have y = 0, so q = (0-1)/2 = -0.5 and with
    ! factor 1 s = 1 + 0.5*(1 - 0.25) = 1.375; only x/z scale about
    ! the centroid, y is unchanged: v1 x' = 1 + (0-1)*1.375 = -0.375,
    ! v2 x' = 1 + (3-1)*1.375 = 3.75.
    call make_tri(tri, vec3_create(0.0_dp, 0.0_dp, 0.0_dp), &
                       vec3_create(3.0_dp, 0.0_dp, 0.0_dp), &
                       vec3_create(0.0_dp, 3.0_dp, 0.0_dp))
    call morph_apply(tri, 'bulge', 1.0_dp, tri_out)
    call assert_vec3_close(tri_out%triangles(1)%v(1), &
        vec3_create(-0.375_dp, 0.0_dp, 0.0_dp), 1.0e-9_dp, &
        'bulge factor 1: q=-0.5 vertex x scaled by s=1.375, y unchanged')
    call assert_vec3_close(tri_out%triangles(1)%v(2), &
        vec3_create(3.75_dp, 0.0_dp, 0.0_dp), 1.0e-9_dp, &
        'bulge factor 1: second q=-0.5 vertex x scaled by s=1.375')
    ! Vertex 3 has y = 3, so q = (3-1)/2 = +1 (a pole height): s = 1,
    ! unchanged.
    call assert_vec3_close(tri_out%triangles(1)%v(3), &
        vec3_create(0.0_dp, 3.0_dp, 0.0_dp), 1.0e-9_dp, &
        'bulge factor 1: vertex at q=+1 (pole height) is unchanged')
    call assert_vec3_close(tri_out%triangles(1)%normal, &
        compute_triangle_normal(tri_out%triangles(1)%v(1), &
                                tri_out%triangles(1)%v(2), &
                                tri_out%triangles(1)%v(3)), 0.0_dp, &
        'bulge recomputes normals via compute_triangle_normal')

    ! A vertex sitting exactly on the centroid never moves under bulge
    ! (its x/z offsets from the centroid are 0 whatever s is).
    ! Centroid of this triangle is (1,1,0), which is vertex 1 itself.
    call make_tri(tri, vec3_create(1.0_dp, 1.0_dp, 0.0_dp), &
                       vec3_create(0.0_dp, 0.0_dp, 0.0_dp), &
                       vec3_create(2.0_dp, 2.0_dp, 0.0_dp))
    call morph_apply(tri, 'bulge', 2.0_dp, tri_out)
    call assert_vec3_close(tri_out%triangles(1)%v(1), &
        vec3_create(1.0_dp, 1.0_dp, 0.0_dp), 1.0e-9_dp, &
        'bulge: vertex at the centroid stays at the centroid')

    ! Documented cube case: on a size-2 cube every corner has
    ! y = cy +/- 1 with halfh = 1, so q = +/-1, s = 1 and bulge
    ! leaves the cube exactly unchanged (bit-identical vertices).
    call morph_apply(cube, 'bulge', 1.0_dp, out)
    call assert_true(all_vertices_exact(cube, out), &
        'bulge: size-2 cube corners are all at q=+/-1, so unchanged')

    ! Sphere-like case (custom mesh, exact arithmetic): centroid
    ! (0,0,0), halfh = 2.  Vertex 1 is an equator vertex (y == cy,
    ! radius 2 in x), so q = 0 and with factor 1 its x scales by
    ! exactly (1 + 0.5*factor) = 1.5.  Vertex 2 is a pole vertex
    ! (x == cx, z == cz, q = +1): unchanged.  Vertex 3 is at
    ! q = -1: unchanged.
    call make_tri(tri, vec3_create(2.0_dp, 0.0_dp, 0.0_dp), &
                       vec3_create(0.0_dp, 2.0_dp, 0.0_dp), &
                       vec3_create(-2.0_dp, -2.0_dp, 0.0_dp))
    call morph_apply(tri, 'bulge', 1.0_dp, tri_out)
    call assert_vec3_close(tri_out%triangles(1)%v(1), &
        vec3_create(3.0_dp, 0.0_dp, 0.0_dp), 1.0e-12_dp, &
        'bulge: equator vertex (q=0) x/z scaled by exactly 1+0.5*factor')
    call assert_vec3_close(tri_out%triangles(1)%v(2), &
        vec3_create(0.0_dp, 2.0_dp, 0.0_dp), 1.0e-12_dp, &
        'bulge: pole vertex (x=cx, z=cz, q=+1) is unchanged')
    call assert_vec3_close(tri_out%triangles(1)%v(3), &
        vec3_create(-2.0_dp, -2.0_dp, 0.0_dp), 1.0e-12_dp, &
        'bulge: vertex at q=-1 is unchanged')

    ! Real sphere (the canonical morph target the old radial formula
    ! left untouched): radius 2, segments 8 -> rings 6, so ring j=3
    ! lies on the equator (y == cy up to rounding).  With factor 1
    ! every equator vertex must scale in x/z by (1 + 0.5*factor),
    ! y unchanged; the top pole (triangle 1, vertex 1 by
    ! construction) must be unchanged.
    call create_sphere(sph, 2.0_dp, 8)
    call morph_apply(sph, 'bulge', 1.0_dp, sph_out)
    eq_count = 0
    eq_maxerr = 0.0_dp
    do si = 1, sph%num_triangles
        do sk = 1, 3
            if (abs(sph%triangles(si)%v(sk)%y) < 1.0e-9_dp .and. &
                sph%triangles(si)%v(sk)%x * sph%triangles(si)%v(sk)%x + &
                sph%triangles(si)%v(sk)%z * sph%triangles(si)%v(sk)%z &
                > 3.9_dp) then
                eq_count = eq_count + 1
                eq_maxerr = max(eq_maxerr, abs( &
                    sph_out%triangles(si)%v(sk)%x - &
                    1.5_dp * sph%triangles(si)%v(sk)%x))
                eq_maxerr = max(eq_maxerr, abs( &
                    sph_out%triangles(si)%v(sk)%z - &
                    1.5_dp * sph%triangles(si)%v(sk)%z))
                eq_maxerr = max(eq_maxerr, abs( &
                    sph_out%triangles(si)%v(sk)%y - &
                    sph%triangles(si)%v(sk)%y))
            end if
        end do
    end do
    call assert_true(eq_count > 0, &
        'bulge sphere: equator vertices were found on the sphere')
    call assert_real_close(eq_maxerr, 0.0_dp, 1.0e-9_dp, &
        'bulge sphere: equator vertices scale x/z by 1+0.5*factor, y kept')
    call assert_vec3_close(sph_out%triangles(1)%v(1), &
        vec3_create(0.0_dp, 2.0_dp, 0.0_dp), 1.0e-12_dp, &
        'bulge sphere: pole vertex is unchanged')

    ! Flat mesh: every vertex at the same y, so halfh == 0 and bulge
    ! copies the mesh unchanged.
    call make_tri(tri, vec3_create(0.0_dp, 5.0_dp, 0.0_dp), &
                       vec3_create(3.0_dp, 5.0_dp, 0.0_dp), &
                       vec3_create(0.0_dp, 5.0_dp, 3.0_dp))
    call morph_apply(tri, 'bulge', 1.0_dp, tri_out)
    call assert_true(all_vertices_exact(tri, tri_out), &
        'bulge: halfh == 0 (flat mesh) copies the mesh unchanged')

    ! ================= morph: taper ==================================
    ! Triangle A(4,2,6), B(0,0,0), C(2,1,0): centroid (2,1,2),
    ! ymin=0, ymax=2.  A has h=1, so with factor 1 its x/z are scaled
    ! about the centroid by exactly (1 - 0.5*1) = 0.5:
    ! x' = 2 + (4-2)*0.5 = 3, z' = 2 + (6-2)*0.5 = 4, y unchanged.
    call make_tri(tri, vec3_create(4.0_dp, 2.0_dp, 6.0_dp), &
                       vec3_create(0.0_dp, 0.0_dp, 0.0_dp), &
                       vec3_create(2.0_dp, 1.0_dp, 0.0_dp))
    call morph_apply(tri, 'taper', 1.0_dp, tri_out)
    call assert_vec3_close(tri_out%triangles(1)%v(1), &
        vec3_create(3.0_dp, 2.0_dp, 4.0_dp), 1.0e-12_dp, &
        'taper: top vertex (h=1) x/z scaled by exactly (1-0.5*factor)')
    ! B has h=0, so s=1: unchanged.
    call assert_vec3_close(tri_out%triangles(1)%v(2), &
        vec3_create(0.0_dp, 0.0_dp, 0.0_dp), 1.0e-12_dp, &
        'taper: bottom vertex (h=0) is unchanged')

    ! ================= morph: squash =================================
    ! Same triangle / centroid (2,1,2), factor 1: y scale (1-0.5)=0.5,
    ! x/z scale (1+0.25)=1.25.  A(4,2,6) ->
    ! (2 + 2*1.25, 1 + 1*0.5, 2 + 4*1.25) = (4.5, 1.5, 7).
    call morph_apply(tri, 'squash', 1.0_dp, tri_out)
    call assert_vec3_close(tri_out%triangles(1)%v(1), &
        vec3_create(4.5_dp, 1.5_dp, 7.0_dp), 1.0e-12_dp, &
        'squash: y scaled by (1-0.5*factor), x/z by (1+0.25*factor)')

    ! ================= skin_weight ===================================
    call assert_real_close(skin_weight(0.0_dp, 2.0_dp), 1.0_dp, 0.0_dp, &
        'skin_weight at d=0 is exactly 1')
    call assert_real_close(skin_weight(2.0_dp, 2.0_dp), 0.0_dp, 0.0_dp, &
        'skin_weight at d=radius is exactly 0')
    call assert_real_close(skin_weight(1.0_dp, 2.0_dp), 0.5_dp, 0.0_dp, &
        'skin_weight at d=radius/2 is exactly 0.5 (smoothstep)')
    call assert_real_close(skin_weight(3.0_dp, 2.0_dp), 0.0_dp, 0.0_dp, &
        'skin_weight beyond radius is 0')
    call assert_real_close(skin_weight(0.0_dp, 0.0_dp), 0.0_dp, 0.0_dp, &
        'skin_weight with radius<=0 is 0 (documented definition)')

    ! ================= skin_apply ====================================
    rotz90 = vec3_create(0.0_dp, 0.0_dp, 90.0_dp)

    ! Cube vertex (-1,-1,-1) (tri 1, vertex 1), pivot at the origin,
    ! radius 10, Rz(+90): the fully rotated position is (1,-1,-1)
    ! ((x,y) -> (-y,x)) and the analytic position under the contract
    ! is the skin_weight blend of the original and that position
    ! (w = skin_weight(sqrt(3), 10); w = 1 only at the pivot itself,
    ! which the at-pivot case below covers).
    pivot = vec3_create(0.0_dp, 0.0_dp, 0.0_dp)
    call skin_apply(cube, pivot, rotz90, 10.0_dp, out)
    p_orig = cube%triangles(1)%v(1)
    w = skin_weight(vec3_norm(vec3_sub(p_orig, pivot)), 10.0_dp)
    mp = mat4_transform_vec3(mat4_rotate_z(deg2rad(90.0_dp)), p_orig, .true.)
    expect = vec3_create((1.0_dp - w) * p_orig%x + w * mp%x, &
                         (1.0_dp - w) * p_orig%y + w * mp%y, &
                         (1.0_dp - w) * p_orig%z + w * mp%z)
    call assert_vec3_close(out%triangles(1)%v(1), expect, 1.0e-9_dp, &
        'skin: cube vertex rotated 90 deg about z maps to analytic position')
    call assert_vec3_close(mp, vec3_create(1.0_dp, -1.0_dp, -1.0_dp), &
        1.0e-9_dp, &
        'skin: full Rz90 rotation of (-1,-1,-1) is (1,-1,-1)')

    ! Vertex AT the pivot (w=1) moves exactly as M*p; M fixes the
    ! pivot, so it stays at the pivot.
    pivot = vec3_create(2.0_dp, 3.0_dp, 0.0_dp)
    call make_tri(tri, vec3_create(2.0_dp, 3.0_dp, 0.0_dp), &
                       vec3_create(9.0_dp, 3.0_dp, 0.0_dp), &
                       vec3_create(2.0_dp, 9.0_dp, 0.0_dp))
    call skin_apply(tri, pivot, rotz90, 5.0_dp, tri_out)
    bone = mat4_mult(mat4_translation(pivot%x, pivot%y, pivot%z), &
           mat4_mult(mat4_rotate_z(deg2rad(90.0_dp)), &
                     mat4_translation(-pivot%x, -pivot%y, -pivot%z)))
    expect = mat4_transform_vec3(bone, tri%triangles(1)%v(1), .true.)
    call assert_vec3_close(tri_out%triangles(1)%v(1), expect, 1.0e-9_dp, &
        'skin: vertex at the pivot moves exactly as M*p (w=1)')
    call assert_vec3_close(tri_out%triangles(1)%v(1), pivot, 1.0e-9_dp, &
        'skin: vertex at the pivot stays at the pivot under rotation')

    ! Far vertices: every cube vertex is at dist sqrt(3) > radius 1
    ! from the origin, so all positions are bit-identical.
    pivot = vec3_create(0.0_dp, 0.0_dp, 0.0_dp)
    call skin_apply(cube, pivot, rotz90, 1.0_dp, out)
    call assert_true(all_vertices_exact(cube, out), &
        'skin: vertices at dist >= radius are bit-identical to input')

    ! Partial weight: P(1,0,0), pivot origin, radius 2 -> w = 0.5.
    ! Fully rotated Mp = Rz90 * P = (0,1,0); blend = (0.5, 0.5, 0).
    call make_tri(tri, vec3_create(1.0_dp, 0.0_dp, 0.0_dp), &
                       vec3_create(0.0_dp, 0.0_dp, 5.0_dp), &
                       vec3_create(0.0_dp, 5.0_dp, 0.0_dp))
    call skin_apply(tri, pivot, rotz90, 2.0_dp, tri_out)
    call assert_vec3_close(tri_out%triangles(1)%v(1), &
        vec3_create(0.5_dp, 0.5_dp, 0.0_dp), 1.0e-9_dp, &
        'skin: partial-weight vertex lands at the (1-w)/w blend position')
    p_orig = tri%triangles(1)%v(1)
    w = skin_weight(vec3_norm(vec3_sub(p_orig, pivot)), 2.0_dp)
    mp = mat4_transform_vec3(mat4_rotate_z(deg2rad(90.0_dp)), p_orig, .true.)
    expect = vec3_create((1.0_dp - w) * p_orig%x + w * mp%x, &
                         (1.0_dp - w) * p_orig%y + w * mp%y, &
                         (1.0_dp - w) * p_orig%z + w * mp%z)
    call assert_vec3_close(tri_out%triangles(1)%v(1), expect, 1.0e-12_dp, &
        'skin: partial-weight vertex equals (1-w)*p + w*(M*p) exactly')
    call assert_vec3_close(tri_out%triangles(1)%normal, &
        compute_triangle_normal(tri_out%triangles(1)%v(1), &
                                tri_out%triangles(1)%v(2), &
                                tri_out%triangles(1)%v(3)), 0.0_dp, &
        'skin recomputes normals via compute_triangle_normal')

    call free_mesh(cube)
    call free_mesh(out)
    call free_mesh(tri)
    call free_mesh(tri_out)
    call free_mesh(sph)
    call free_mesh(sph_out)

    call test_summary()

contains

    subroutine make_tri(m, a, b, c)
        type(Mesh), intent(inout) :: m
        type(vec3), intent(in) :: a, b, c

        if (allocated(m%triangles)) deallocate(m%triangles)
        m%num_triangles = 1
        allocate(m%triangles(1))
        m%triangles(1)%v = [a, b, c]
        m%triangles(1)%normal = compute_triangle_normal(a, b, c)
        m%triangles(1)%color = [10, 20, 30]
        m%triangles(1)%material_id = 0
    end subroutine make_tri

    logical function all_vertices_exact(a, b) result(ok)
        type(Mesh), intent(in) :: a, b
        integer :: ii, kk

        ok = (a%num_triangles == b%num_triangles)
        if (.not. ok) return
        do ii = 1, a%num_triangles
            do kk = 1, 3
                if (a%triangles(ii)%v(kk)%x /= b%triangles(ii)%v(kk)%x .or. &
                    a%triangles(ii)%v(kk)%y /= b%triangles(ii)%v(kk)%y .or. &
                    a%triangles(ii)%v(kk)%z /= b%triangles(ii)%v(kk)%z) ok = .false.
            end do
        end do
    end function all_vertices_exact

end program test_skinning
