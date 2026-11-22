! skinning.f90 -- C1 skinning + morph targets (Wave E, seat E05).
!
! Two deformation families over an ordinary Mesh:
!
!   morph_apply -- named morph targets ('bulge', 'taper', 'squash')
!                  driven by a scalar factor, deforming every vertex
!                  relative to the mesh centroid (the mean of ALL
!                  triangle vertices).
!                  bulge: barrel profile — x/z scale s = 1 + factor*0.5*(1 - q^2), q = (y - cy)/halfh, strongest at the middle height, poles unchanged
!   skin_apply  -- single-bone linear-blend skinning: vertices within
!                  `radius` of `pivot` are blended toward the rigid
!                  transform that rotates about the pivot, with the
!                  smoothstep weight skin_weight(|p - pivot|, radius).
!
! Both produce a FRESH copy in mesh_out (triangles, colours and
! material ids copied from mesh_in) and recompute every triangle
! normal via compute_triangle_normal after deformation.  mesh_in is
! never modified.
module skinning_3d
    use math_3d
    use mesh_3d
    implicit none
    private
    public :: morph_apply, skin_weight, skin_apply

contains

    ! Deep-copy src into dst (dst is reset first).
    subroutine copy_mesh(src, dst)
        type(Mesh), intent(in) :: src
        type(Mesh), intent(inout) :: dst
        integer :: n

        if (allocated(dst%triangles)) deallocate(dst%triangles)
        dst%num_triangles = src%num_triangles
        n = src%num_triangles
        if (n > 0) then
            allocate(dst%triangles(n))
            dst%triangles(1:n) = src%triangles(1:n)
        end if
    end subroutine copy_mesh

    subroutine recompute_normals(m)
        type(Mesh), intent(inout) :: m
        integer :: i

        do i = 1, m%num_triangles
            m%triangles(i)%normal = compute_triangle_normal( &
                m%triangles(i)%v(1), m%triangles(i)%v(2), m%triangles(i)%v(3))
        end do
    end subroutine recompute_normals

    ! Mean of ALL triangle vertices (every triangle contributes its
    ! three vertices, duplicates included).
    function mesh_centroid(m) result(c)
        type(Mesh), intent(in) :: m
        type(vec3) :: c
        integer :: i, k
        real(dp) :: n

        c = vec3_create(0.0_dp, 0.0_dp, 0.0_dp)
        if (m%num_triangles <= 0) return
        do i = 1, m%num_triangles
            do k = 1, 3
                c = vec3_add(c, m%triangles(i)%v(k))
            end do
        end do
        n = real(3 * m%num_triangles, dp)
        c = vec3_scale(c, 1.0_dp / n)
    end function mesh_centroid

    ! Named morph targets.  Unknown kind -> copy unchanged.
    ! factor == 0 is an EXACT identity for every kind (the copy is
    ! returned verbatim, so vertices and normals are bit-identical).
    subroutine morph_apply(mesh_in, kind, factor, mesh_out)
        type(Mesh), intent(in) :: mesh_in
        character(len=*), intent(in) :: kind
        real(dp), intent(in) :: factor
        type(Mesh), intent(inout) :: mesh_out
        type(vec3) :: centroid, p
        real(dp) :: s, ymin, ymax, h, halfh, q
        integer :: i, k
        logical :: known

        call copy_mesh(mesh_in, mesh_out)
        if (mesh_out%num_triangles <= 0) return
        if (factor == 0.0_dp) return

        known = (kind == 'bulge') .or. (kind == 'taper') .or. (kind == 'squash')
        if (.not. known) return

        centroid = mesh_centroid(mesh_in)

        select case (kind)
        case ('bulge')
            ! bulge: barrel profile — x/z scale s = 1 + factor*0.5*(1 - q^2), q = (y - cy)/halfh, strongest at the middle height, poles unchanged
            ! halfh = max |y - cy| over all vertices; y is unchanged.
            halfh = 0.0_dp
            do i = 1, mesh_in%num_triangles
                do k = 1, 3
                    halfh = max(halfh, &
                        abs(mesh_in%triangles(i)%v(k)%y - centroid%y))
                end do
            end do
            if (halfh == 0.0_dp) return
            do i = 1, mesh_out%num_triangles
                do k = 1, 3
                    p = mesh_out%triangles(i)%v(k)
                    q = (p%y - centroid%y) / halfh
                    s = 1.0_dp + factor * 0.5_dp * (1.0_dp - q * q)
                    mesh_out%triangles(i)%v(k) = vec3_create( &
                        centroid%x + (p%x - centroid%x) * s, &
                        p%y, &
                        centroid%z + (p%z - centroid%z) * s)
                end do
            end do

        case ('taper')
            ymin = mesh_in%triangles(1)%v(1)%y
            ymax = ymin
            do i = 1, mesh_in%num_triangles
                do k = 1, 3
                    ymin = min(ymin, mesh_in%triangles(i)%v(k)%y)
                    ymax = max(ymax, mesh_in%triangles(i)%v(k)%y)
                end do
            end do
            if (ymax == ymin) return
            do i = 1, mesh_out%num_triangles
                do k = 1, 3
                    p = mesh_out%triangles(i)%v(k)
                    h = (p%y - ymin) / (ymax - ymin)
                    s = 1.0_dp - factor * 0.5_dp * h
                    mesh_out%triangles(i)%v(k) = vec3_create( &
                        centroid%x + (p%x - centroid%x) * s, &
                        p%y, &
                        centroid%z + (p%z - centroid%z) * s)
                end do
            end do

        case ('squash')
            do i = 1, mesh_out%num_triangles
                do k = 1, 3
                    p = mesh_out%triangles(i)%v(k)
                    mesh_out%triangles(i)%v(k) = vec3_create( &
                        centroid%x + (p%x - centroid%x) * (1.0_dp + 0.25_dp * factor), &
                        centroid%y + (p%y - centroid%y) * (1.0_dp - 0.5_dp * factor), &
                        centroid%z + (p%z - centroid%z) * (1.0_dp + 0.25_dp * factor))
                end do
            end do
        end select

        call recompute_normals(mesh_out)
    end subroutine morph_apply

    ! Smoothstep falloff weight.
    !   s = clamp(1 - dist/radius, 0, 1);  w = s*s*(3 - 2*s).
    ! radius <= 0 is defined to give w = 0 for every dist (no
    ! influence region at all), including dist == 0.
    pure function skin_weight(dist, radius) result(w)
        real(dp), intent(in) :: dist, radius
        real(dp) :: w, s

        if (radius <= 0.0_dp) then
            w = 0.0_dp
            return
        end if
        s = 1.0_dp - dist / radius
        if (s < 0.0_dp) s = 0.0_dp
        if (s > 1.0_dp) s = 1.0_dp
        w = s * s * (3.0_dp - 2.0_dp * s)
    end function skin_weight

    ! Single-bone skinning about `pivot`.
    ! Bone matrix M = T(pivot) * Rz * Ry * Rx * T(-pivot), with the
    ! rotation angles taken from rot_deg in DEGREES (converted with
    ! deg2rad for the radian-taking mat4_rotate_* constructors).
    ! Per vertex: w = skin_weight(|p - pivot|, radius) and
    ! p' = (1-w)*p + w*(M*p).  Vertices with w == 0 (in particular
    ! dist >= radius) keep their input position bit-identically, and
    ! vertices with w == 1 take exactly M*p.
    subroutine skin_apply(mesh_in, pivot, rot_deg, radius, mesh_out)
        type(Mesh), intent(in) :: mesh_in
        type(vec3), intent(in) :: pivot, rot_deg
        real(dp), intent(in) :: radius
        type(Mesh), intent(inout) :: mesh_out
        type(mat4) :: bone, rx, ry, rz
        type(vec3) :: p, mp
        real(dp) :: dist, w
        integer :: i, k

        call copy_mesh(mesh_in, mesh_out)
        if (mesh_out%num_triangles <= 0) return

        rx = mat4_rotate_x(deg2rad(rot_deg%x))
        ry = mat4_rotate_y(deg2rad(rot_deg%y))
        rz = mat4_rotate_z(deg2rad(rot_deg%z))
        bone = mat4_mult(mat4_translation(pivot%x, pivot%y, pivot%z), &
               mat4_mult(rz, &
               mat4_mult(ry, &
               mat4_mult(rx, &
                         mat4_translation(-pivot%x, -pivot%y, -pivot%z)))))

        do i = 1, mesh_out%num_triangles
            do k = 1, 3
                p = mesh_out%triangles(i)%v(k)
                dist = vec3_norm(vec3_sub(p, pivot))
                w = skin_weight(dist, radius)
                if (w == 0.0_dp) then
                    cycle
                else if (w == 1.0_dp) then
                    mesh_out%triangles(i)%v(k) = &
                        mat4_transform_vec3(bone, p, .true.)
                else
                    mp = mat4_transform_vec3(bone, p, .true.)
                    mesh_out%triangles(i)%v(k) = vec3_create( &
                        (1.0_dp - w) * p%x + w * mp%x, &
                        (1.0_dp - w) * p%y + w * mp%y, &
                        (1.0_dp - w) * p%z + w * mp%z)
                end if
            end do
        end do

        call recompute_normals(mesh_out)
    end subroutine skin_apply

end module skinning_3d
