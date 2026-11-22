! test_shadow_clipping.f90 -- clip-space clipping in the shadow depth
! rasteriser (defect D2 pattern, docs/plan/WB-INV-PLANE.md).
!
! Before the fix, shadow_add_mesh projected with an unconditional w
! divide (via mat4_transform_vec3), so a caster crossing the light
! camera's near plane -- or behind the light -- flipped in NDC and
! either vanished or corrupted the depth map.  These tests pin:
!   1. a fully-inside caster producing depth values identical to the
!      pre-clipping reference (the test_shadow.f90 scenario/values);
!   2. a caster with one vertex behind the light still casting the
!      coherent shadow of its clipped (visible) part;
!   3. casters fully behind the light, or fully inside the near
!      plane, filling nothing at all.
program test_shadow_clipping
    use math_3d
    use mesh_3d
    use shadow_3d
    use test_assert
    implicit none

    type(ShadowMap) :: smap
    type(Mesh) :: cube, tri_mesh
    type(mat4) :: identity
    integer :: filled
    real(dp) :: f

    identity = mat4_identity()

    ! ---- 1. fully inside: identical to the pre-clipping reference ----
    ! Same scene as test_shadow.f90: cube size 2 at the origin, light
    ! at (0,5,0) looking at the origin, 64x64 map, fov 60, near 1,
    ! far 20.  Every cube vertex is inside the light frustum, so this
    ! exercises the unclipped path only.  Reference values, measured
    ! with the pre-clipping implementation (and analytic where noted):
    !   filled cells = 784 (a 28x28 block)
    !   centre depth = 0.7543859649122807 -- the cube's bottom face,
    !     all four vertices at light distance 6, whose NDC z is
    !     (21*6 - 40) / (19*6) = 86/114 exactly.
    call create_cube(cube, 2.0_dp)
    call shadow_begin(smap, vec3_create(0.0_dp, 5.0_dp, 0.0_dp), &
        vec3_create(0.0_dp, 0.0_dp, 0.0_dp), 64, 60.0_dp, 1.0_dp, 20.0_dp)
    call shadow_add_mesh(smap, cube, identity)
    call shadow_end(smap)

    filled = count_filled(smap)
    call assert_int_eq(784, filled, 'fully-inside cube fills exactly 784 cells (as before)')
    call assert_real_close(0.7543859649122807_dp, smap%depth(32, 32), 1.0e-9_dp, &
        'fully-inside cube centre depth identical to reference')
    ! The behavioural checks from test_shadow.f90, unchanged: they are
    ! sensitive to any change in the unclipped rasterisation (the PCF
    ! edge value especially).
    f = shadow_factor(smap, vec3_create(0.0_dp, -1.5_dp, 0.0_dp), 0.002_dp)
    call assert_real_close(0.0_dp, f, 1.0e-12_dp, 'inside: point under cube centre is shadowed')
    f = shadow_factor(smap, vec3_create(3.0_dp, -1.5_dp, 0.0_dp), 0.002_dp)
    call assert_real_close(1.0_dp, f, 1.0e-12_dp, 'inside: in-frustum point outside shadow is lit')
    f = shadow_factor(smap, vec3_create(0.0_dp, 1.0_dp, 0.0_dp), 0.002_dp)
    call assert_real_close(1.0_dp, f, 1.0e-12_dp, 'inside: point on lit top surface is lit')
    f = shadow_factor_pcf(smap, vec3_create(1.60_dp, -1.5_dp, 0.0_dp), 0.002_dp)
    call assert_real_close(1.0_dp / 3.0_dp, f, 1.0e-12_dp, &
        'inside: PCF at shadow edge is still exactly 1/3')
    call shadow_free(smap)
    call free_mesh(cube)

    ! ---- 2. crossing the near plane / behind the light ----
    ! Light at (0,0,5) looking at the origin, fov 90, near 1, far 20,
    ! 64x64 map, so NDC x = x / (5 - z), y = y / (5 - z) and the near
    ! plane is the world plane z = 4.  One triangle:
    !   A = (-2,-1,0)  inside (NDC -0.4, -0.2)
    !   B = ( 0, 2,6)  BEHIND the light (w = -1): pre-fix its divide
    !                  flipped it to NDC y = -2 and the whole triangle
    !                  was winding-culled -- measured filled = 0.
    !   C = ( 2,-1,0)  inside (NDC 0.4, -0.2)
    ! Clipping cuts the A-B and C-B edges at the near plane, giving
    ! the trapezoid A, C, (0.667,1,4), (-0.667,1,4) in NDC:
    !   (-0.4,-0.2), (0.4,-0.2), (0.667,1), (-0.667,1)
    ! whose area is (0.8 + 1.3333)/2 * 1.2 = 1.28 of the 4.0 NDC square,
    ! i.e. about 0.32 * 4096 = 1310 cells.  The sane band below is
    ! 800..2000: centred on that 1310 (integer barycentric rasterising
    ! measured 1284), wide enough for edge rounding, and far from both
    ! failure modes -- 0 (flipped/cull-vanished) and ~4096 (flipped
    ! full-map garbage).
    call make_triangle(tri_mesh, &
        vec3_create(-2.0_dp, -1.0_dp, 0.0_dp), &
        vec3_create(0.0_dp, 2.0_dp, 6.0_dp), &
        vec3_create(2.0_dp, -1.0_dp, 0.0_dp))
    call shadow_begin(smap, vec3_create(0.0_dp, 0.0_dp, 5.0_dp), &
        vec3_create(0.0_dp, 0.0_dp, 0.0_dp), 64, 90.0_dp, 1.0_dp, 20.0_dp)
    call shadow_add_mesh(smap, tri_mesh, identity)
    call shadow_end(smap)

    filled = count_filled(smap)
    call assert_true(filled >= 800 .and. filled <= 2000, &
        'crossing caster fills a sane band around the analytic ~1310 cells')
    call assert_true(smap%depth(32, 32) < 1.0e9_dp, &
        'crossing caster fills the map centre where the clipped polygon lands')
    call assert_true(smap%depth(32, 32) >= -1.0_dp .and. &
        smap%depth(32, 32) <= 1.0_dp, 'crossing caster centre depth is a valid NDC z')
    call assert_true(smap%depth(8, 8) > 1.0e9_dp, &
        'crossing caster leaves the far corner empty (no full-map garbage)')
    call assert_true(smap%depth(32, 48) > 1.0e9_dp, &
        'crossing caster leaves the region below its base empty')
    ! The clipped shadow is usable: the origin, behind the caster
    ! along the light ray, is shadowed; a point beside the trapezoid
    ! (still inside the frustum) is lit.
    f = shadow_factor(smap, vec3_create(0.0_dp, 0.0_dp, 0.0_dp), 0.002_dp)
    call assert_real_close(0.0_dp, f, 1.0e-12_dp, 'point behind crossing caster is shadowed')
    f = shadow_factor(smap, vec3_create(3.0_dp, 0.0_dp, 0.0_dp), 0.002_dp)
    call assert_real_close(1.0_dp, f, 1.0e-12_dp, 'point beside crossing caster shadow is lit')
    call shadow_free(smap)

    ! ---- 3a. fully behind the light fills nothing ----
    call make_triangle(tri_mesh, &
        vec3_create(-2.0_dp, -1.0_dp, 6.0_dp), &
        vec3_create(0.0_dp, 2.0_dp, 7.0_dp), &
        vec3_create(2.0_dp, -1.0_dp, 6.0_dp))
    call shadow_begin(smap, vec3_create(0.0_dp, 0.0_dp, 5.0_dp), &
        vec3_create(0.0_dp, 0.0_dp, 0.0_dp), 64, 90.0_dp, 1.0_dp, 20.0_dp)
    call shadow_add_mesh(smap, tri_mesh, identity)
    call shadow_end(smap)
    call assert_int_eq(0, count_filled(smap), 'fully-behind caster fills nothing')
    f = shadow_factor(smap, vec3_create(0.0_dp, 0.0_dp, 0.0_dp), 0.002_dp)
    call assert_real_close(1.0_dp, f, 1.0e-12_dp, 'fully-behind caster shadows nothing')
    call shadow_free(smap)

    ! ---- 3b. fully inside the near plane fills nothing ----
    ! All vertices at world z = 4.5: in front of the light (distance
    ! 0.5) but nearer than near = 1, so the near plane clips them all.
    call make_triangle(tri_mesh, &
        vec3_create(-1.0_dp, -1.0_dp, 4.5_dp), &
        vec3_create(0.0_dp, 1.0_dp, 4.5_dp), &
        vec3_create(1.0_dp, -1.0_dp, 4.5_dp))
    call shadow_begin(smap, vec3_create(0.0_dp, 0.0_dp, 5.0_dp), &
        vec3_create(0.0_dp, 0.0_dp, 0.0_dp), 64, 90.0_dp, 1.0_dp, 20.0_dp)
    call shadow_add_mesh(smap, tri_mesh, identity)
    call shadow_end(smap)
    call assert_int_eq(0, count_filled(smap), 'caster inside the near plane fills nothing')
    call shadow_free(smap)

    call free_mesh(tri_mesh)
    call test_summary()

contains

    integer function count_filled(m) result(n)
        type(ShadowMap), intent(in) :: m
        integer :: i, j
        n = 0
        do j = 1, m%size
            do i = 1, m%size
                if (m%depth(i, j) < 1.0e9_dp) n = n + 1
            end do
        end do
    end function count_filled

    subroutine make_triangle(m, a, b, c)
        type(Mesh), intent(inout) :: m
        type(vec3), intent(in) :: a, b, c
        if (allocated(m%triangles)) deallocate(m%triangles)
        allocate(m%triangles(1))
        m%num_triangles = 1
        m%triangles(1)%v = [a, b, c]
    end subroutine make_triangle

end program test_shadow_clipping
