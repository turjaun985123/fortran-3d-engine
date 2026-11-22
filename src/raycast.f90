! raycast.f90 -- native raycasting / picking (MASTER-PLAN row 20).
!
! A ray is origin + t * dir for t >= 0.  dir need NOT be normalised:
! t is measured in dir units, so doubling dir halves the t of the
! same geometric point.
!
! Intersection is Moller-Trumbore, per triangle, against the mesh
! transformed by the model matrix (vertices are transformed to world
! space with mat4_transform_vec3, exactly as renderer.f90 does).
! The nearest hit with t > 1.0e-9 wins; ties (a hit exactly on an
! edge shared by two triangles) resolve deterministically to the
! lowest triangle index, because a candidate only replaces the
! current best when its t is strictly smaller.
!
! Backfaces: BOTH windings are accepted.  There is deliberately no
! det > 0 (front-face-only) test: this engine's renderer is
! far-side-visible in places (see the winding note in shadow.f90),
! and picking must be able to select what the user can see, which
! includes far-side faces and faces seen from inside a mesh.  The
! only determinant test is |det| < 1.0e-9 (ray parallel to, or
! triangle degenerate in, the ray direction).
!
! Barycentric acceptance is exact, with no negative tolerance:
! u >= 0, v >= 0 and u + v <= 1, all as computed.  That keeps the
! result deterministic and reproducible across compilers.
!
! Note on `pure`: ray_triangle is specified as a pure function with
! (t, u, v) outputs, but Fortran forbids INTENT(OUT) dummy arguments
! in a pure function, so it is declared as a plain function.  It is
! pure in effect: it reads only its inputs, writes only t, u, v and
! its result, and touches no module or global state.
module raycast_3d
    use math_3d
    use mesh_3d
    implicit none
    private
    public :: RayHit, ray_cast_mesh, ray_triangle

    real(dp), parameter :: RAY_EPS = 1.0e-9_dp

    type :: RayHit
        logical :: hit = .false.
        real(dp) :: t = 0.0_dp          ! ray parameter, point = origin + t*dir (dir need not be normalised; t in dir units)
        integer :: tri_index = 0        ! 1-based triangle index in the mesh
        real(dp) :: bary(3) = 0.0_dp    ! barycentric weights of the hit point
        type(vec3) :: point             ! world/object-space hit point
    end type RayHit

contains

    ! Moller-Trumbore ray/triangle intersection, the testable core.
    ! On a hit, returns .true. and sets:
    !   t = ray parameter of the hit (in dir units, t > 1.0e-9)
    !   u = barycentric weight of v2, v = barycentric weight of v3
    !       (the weight of v1 is 1 - u - v)
    ! On a miss (parallel/degenerate, barycentric outside, or
    ! t <= 1.0e-9) returns .false. and sets t = u = v = 0.
    ! Both windings are accepted (see the module header).
    function ray_triangle(origin, dir, v1, v2, v3, t, u, v) result(hit)
        type(vec3), intent(in) :: origin, dir, v1, v2, v3
        real(dp), intent(out) :: t, u, v
        logical :: hit

        type(vec3) :: edge1, edge2, pvec, tvec, qvec
        real(dp) :: det, inv_det

        hit = .false.
        t = 0.0_dp
        u = 0.0_dp
        v = 0.0_dp

        edge1 = vec3_sub(v2, v1)
        edge2 = vec3_sub(v3, v1)
        pvec = vec3_cross(dir, edge2)
        det = vec3_dot(edge1, pvec)

        ! No sign test on det: both windings hit.  Only (near-)
        ! parallel rays / degenerate triangles are rejected.
        if (abs(det) < RAY_EPS) return
        inv_det = 1.0_dp / det

        tvec = vec3_sub(origin, v1)
        u = vec3_dot(tvec, pvec) * inv_det
        if (u < 0.0_dp .or. u > 1.0_dp) return

        qvec = vec3_cross(tvec, edge1)
        v = vec3_dot(dir, qvec) * inv_det
        if (v < 0.0_dp .or. u + v > 1.0_dp) return

        t = vec3_dot(edge2, qvec) * inv_det
        if (t <= RAY_EPS) then
            t = 0.0_dp
            u = 0.0_dp
            v = 0.0_dp
            return
        end if

        hit = .true.
    end function ray_triangle

    ! Cast a ray against every triangle of mesh, with the mesh
    ! transformed by model_matrix.  hit is always reset first, so a
    ! miss leaves hit%hit = .false., hit%t = 0, hit%tri_index = 0,
    ! hit%bary = 0 and hit%point = (0, 0, 0).  On a hit, hit%point
    ! is origin + t * dir and hit%bary holds the weights of the
    ! triangle's (v1, v2, v3) in that order.
    ! The mesh dummy is named target_mesh, as in renderer.f90 /
    ! shadow.f90: Fortran is case-insensitive, so a dummy named
    ! `mesh` would collide with the type name Mesh.
    subroutine ray_cast_mesh(origin, dir, target_mesh, model_matrix, hit)
        type(vec3), intent(in) :: origin, dir
        type(Mesh), intent(in) :: target_mesh
        type(mat4), intent(in) :: model_matrix
        type(RayHit), intent(out) :: hit

        type(vec3) :: w(3)
        real(dp) :: t, u, v, best_t
        integer :: i

        hit%hit = .false.
        hit%t = 0.0_dp
        hit%tri_index = 0
        hit%bary = 0.0_dp
        hit%point = vec3_create(0.0_dp, 0.0_dp, 0.0_dp)

        if (.not. allocated(target_mesh%triangles)) return
        if (target_mesh%num_triangles <= 0) return

        best_t = huge(1.0_dp)
        do i = 1, target_mesh%num_triangles
            w(1) = mat4_transform_vec3(model_matrix, target_mesh%triangles(i)%v(1), .true.)
            w(2) = mat4_transform_vec3(model_matrix, target_mesh%triangles(i)%v(2), .true.)
            w(3) = mat4_transform_vec3(model_matrix, target_mesh%triangles(i)%v(3), .true.)

            if (.not. ray_triangle(origin, dir, w(1), w(2), w(3), t, u, v)) cycle
            if (t >= best_t) cycle

            best_t = t
            hit%hit = .true.
            hit%t = t
            hit%tri_index = i
            hit%bary = [1.0_dp - u - v, u, v]
            hit%point = vec3_add(origin, vec3_scale(dir, t))
        end do
    end subroutine ray_cast_mesh

end module raycast_3d
