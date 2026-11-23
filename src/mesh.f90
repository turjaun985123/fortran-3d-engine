module mesh_3d
    use math_3d
    implicit none
    private
    public :: Triangle, Mesh, create_cube, compute_triangle_normal, export_mesh_json, export_mesh_obj, &
              free_mesh, create_box, create_sphere, create_cylinder, create_cone, &
              create_plane, create_pyramid, create_torus, mesh_append, mesh_add_transformed, &
              tri_set_smooth

    type :: Triangle
        type(vec3) :: v(3) = [vec3(0.0_dp, 0.0_dp, 0.0_dp), &
                              vec3(0.0_dp, 0.0_dp, 0.0_dp), &
                              vec3(0.0_dp, 0.0_dp, 0.0_dp)]
        type(vec3) :: normal = vec3(0.0_dp, 0.0_dp, 0.0_dp)
        ! Per-vertex normals (P1): vn(i) corresponds to v(i).  Invariant:
        ! vn is always meaningful -- for flat shading (smooth=.false.)
        ! vn(i) == normal for all i; curved builders set analytic vn
        ! via tri_set_smooth and set smooth=.true..
        type(vec3) :: vn(3) = [vec3(0.0_dp, 0.0_dp, 0.0_dp), &
                               vec3(0.0_dp, 0.0_dp, 0.0_dp), &
                               vec3(0.0_dp, 0.0_dp, 0.0_dp)]
        logical :: smooth = .false.
        integer :: color(3) = [255, 255, 255]
        integer :: material_id = 0
    end type Triangle

    type :: Mesh
        integer :: num_triangles
        type(Triangle), allocatable :: triangles(:)
    end type Mesh

contains

    pure function compute_triangle_normal(v1, v2, v3) result(n)
        type(vec3), intent(in) :: v1, v2, v3
        type(vec3) :: n
        type(vec3) :: edge1, edge2
        edge1 = vec3_sub(v2, v1)
        edge2 = vec3_sub(v3, v1)
        n = vec3_normalize(vec3_cross(edge1, edge2))
    end function compute_triangle_normal

    ! Set per-vertex normals on a triangle and mark it smooth-shaded.
    subroutine tri_set_smooth(tri, n1, n2, n3)
        type(Triangle), intent(inout) :: tri
        type(vec3), intent(in) :: n1, n2, n3
        tri%vn = [n1, n2, n3]
        tri%smooth = .true.
    end subroutine tri_set_smooth

    ! Keep vn consistent with the (flat) face normal.
    subroutine tri_set_flat_vn(tri)
        type(Triangle), intent(inout) :: tri
        tri%vn = [tri%normal, tri%normal, tri%normal]
        tri%smooth = .false.
    end subroutine tri_set_flat_vn

    subroutine free_mesh(m)
        type(Mesh), intent(inout) :: m
        if (allocated(m%triangles)) deallocate(m%triangles)
        m%num_triangles = 0
    end subroutine free_mesh

    subroutine create_cube(m, size)
        type(Mesh), intent(inout) :: m
        real(dp), intent(in) :: size
        real(dp) :: h
        type(vec3) :: p(8)
        integer :: i

        if (allocated(m%triangles)) deallocate(m%triangles)

        h = size * 0.5_dp

        ! Define 8 vertices of a box centered at origin
        p(1) = vec3_create(-h, -h, -h)
        p(2) = vec3_create( h, -h, -h)
        p(3) = vec3_create( h,  h, -h)
        p(4) = vec3_create(-h,  h, -h)
        p(5) = vec3_create(-h, -h,  h)
        p(6) = vec3_create( h, -h,  h)
        p(7) = vec3_create( h,  h,  h)
        p(8) = vec3_create(-h,  h,  h)

        m%num_triangles = 12
        allocate(m%triangles(12))

        ! South face (Z = -h)
        m%triangles(1)%v = [p(1), p(3), p(2)]
        m%triangles(2)%v = [p(1), p(4), p(3)]
        ! East face (X = +h)
        m%triangles(3)%v = [p(2), p(7), p(6)]
        m%triangles(4)%v = [p(2), p(3), p(7)]
        ! North face (Z = +h)
        m%triangles(5)%v = [p(6), p(8), p(5)]
        m%triangles(6)%v = [p(6), p(7), p(8)]
        ! West face (X = -h)
        m%triangles(7)%v = [p(5), p(4), p(1)]
        m%triangles(8)%v = [p(5), p(8), p(4)]
        ! Top face (Y = +h)
        m%triangles(9)%v = [p(4), p(7), p(3)]
        m%triangles(10)%v = [p(4), p(8), p(7)]
        ! Bottom face (Y = -h)
        m%triangles(11)%v = [p(5), p(2), p(6)]
        m%triangles(12)%v = [p(5), p(1), p(2)]

        ! Assign colors and calculate normals
        do i = 1, 12
            m%triangles(i)%normal = compute_triangle_normal( &
                m%triangles(i)%v(1), m%triangles(i)%v(2), m%triangles(i)%v(3))
            call tri_set_flat_vn(m%triangles(i))

            ! Color faces uniquely for visual distinction
            select case (i)
            case (1, 2)
                m%triangles(i)%color = [220, 60, 60]   ! Red
            case (3, 4)
                m%triangles(i)%color = [60, 220, 60]   ! Green
            case (5, 6)
                m%triangles(i)%color = [60, 100, 240]  ! Blue
            case (7, 8)
                m%triangles(i)%color = [240, 220, 50]  ! Yellow
            case (9, 10)
                m%triangles(i)%color = [200, 80, 220]  ! Magenta
            case default
                m%triangles(i)%color = [60, 220, 220]  ! Cyan
            end select
        end do
    end subroutine create_cube

    subroutine create_box(m, sx, sy, sz)
        type(Mesh), intent(inout) :: m
        real(dp), intent(in) :: sx, sy, sz
        real(dp) :: hx, hy, hz
        type(vec3) :: p(8)
        integer :: i

        if (allocated(m%triangles)) deallocate(m%triangles)

        hx = sx * 0.5_dp
        hy = sy * 0.5_dp
        hz = sz * 0.5_dp

        ! Same vertex / triangle order and face colours as create_cube.
        p(1) = vec3_create(-hx, -hy, -hz)
        p(2) = vec3_create( hx, -hy, -hz)
        p(3) = vec3_create( hx,  hy, -hz)
        p(4) = vec3_create(-hx,  hy, -hz)
        p(5) = vec3_create(-hx, -hy,  hz)
        p(6) = vec3_create( hx, -hy,  hz)
        p(7) = vec3_create( hx,  hy,  hz)
        p(8) = vec3_create(-hx,  hy,  hz)

        m%num_triangles = 12
        allocate(m%triangles(12))

        m%triangles(1)%v = [p(1), p(3), p(2)]
        m%triangles(2)%v = [p(1), p(4), p(3)]
        m%triangles(3)%v = [p(2), p(7), p(6)]
        m%triangles(4)%v = [p(2), p(3), p(7)]
        m%triangles(5)%v = [p(6), p(8), p(5)]
        m%triangles(6)%v = [p(6), p(7), p(8)]
        m%triangles(7)%v = [p(5), p(4), p(1)]
        m%triangles(8)%v = [p(5), p(8), p(4)]
        m%triangles(9)%v = [p(4), p(7), p(3)]
        m%triangles(10)%v = [p(4), p(8), p(7)]
        m%triangles(11)%v = [p(5), p(2), p(6)]
        m%triangles(12)%v = [p(5), p(1), p(2)]

        do i = 1, 12
            m%triangles(i)%normal = compute_triangle_normal( &
                m%triangles(i)%v(1), m%triangles(i)%v(2), m%triangles(i)%v(3))
            call tri_set_flat_vn(m%triangles(i))
            select case (i)
            case (1, 2)
                m%triangles(i)%color = [220, 60, 60]
            case (3, 4)
                m%triangles(i)%color = [60, 220, 60]
            case (5, 6)
                m%triangles(i)%color = [60, 100, 240]
            case (7, 8)
                m%triangles(i)%color = [240, 220, 50]
            case (9, 10)
                m%triangles(i)%color = [200, 80, 220]
            case default
                m%triangles(i)%color = [60, 220, 220]
            end select
        end do
    end subroutine create_box

    ! UV sphere centred at the origin.
    !   seg   = max(3, segments)          (segments around the equator)
    !   rings = max(2, segments*3/4)      (latitude bands, pole to pole)
    ! Triangle count = segments * (rings - 1) * 2 exactly for this
    ! construction: seg top-fan + seg bottom-fan + (rings-2)*seg*2 band
    ! triangles = 2*seg*(rings-1).  E.g. segments=16 -> rings=12 -> 352.
    ! Per-triangle normal is analytic: the normalised centroid direction
    ! (vertex positions lie on the sphere, so pos/radius is the normal).
    subroutine create_sphere(m, radius, segments)
        type(Mesh), intent(inout) :: m
        real(dp), intent(in) :: radius
        integer, intent(in) :: segments
        integer :: seg, rings, i, j, idx, i2, j2
        type(vec3) :: top, bot, a, b, c, d
        type(vec3) :: centroid

        if (allocated(m%triangles)) deallocate(m%triangles)
        seg = max(3, segments)
        rings = max(2, (seg * 3) / 4)
        m%num_triangles = seg * (rings - 1) * 2
        allocate(m%triangles(m%num_triangles))
        idx = 0
        top = vec3_create(0.0_dp, radius, 0.0_dp)
        bot = vec3_create(0.0_dp, -radius, 0.0_dp)

        ! Top fan (ring j=1)
        do i = 1, seg
            i2 = mod(i, seg) + 1
            a = sphere_point(radius, seg, rings, 1, i)
            b = sphere_point(radius, seg, rings, 1, i2)
            idx = idx + 1
            m%triangles(idx)%v = [top, b, a]
            centroid = vec3_add(vec3_add(top, b), a)
            m%triangles(idx)%normal = vec3_normalize(centroid)
            call tri_set_smooth(m%triangles(idx), vec3_normalize(top), &
                                vec3_normalize(b), vec3_normalize(a))
            m%triangles(idx)%color = [255, 255, 255]
        end do
        ! Middle bands j=1 .. rings-2
        do j = 1, rings - 2
            j2 = j + 1
            do i = 1, seg
                i2 = mod(i, seg) + 1
                a = sphere_point(radius, seg, rings, j, i)
                b = sphere_point(radius, seg, rings, j, i2)
                c = sphere_point(radius, seg, rings, j2, i2)
                d = sphere_point(radius, seg, rings, j2, i)
                idx = idx + 1
                m%triangles(idx)%v = [a, b, c]
                centroid = vec3_add(vec3_add(a, b), c)
                m%triangles(idx)%normal = vec3_normalize(centroid)
                call tri_set_smooth(m%triangles(idx), vec3_normalize(a), &
                                    vec3_normalize(b), vec3_normalize(c))
                m%triangles(idx)%color = [255, 255, 255]
                idx = idx + 1
                m%triangles(idx)%v = [a, c, d]
                centroid = vec3_add(vec3_add(a, c), d)
                m%triangles(idx)%normal = vec3_normalize(centroid)
                call tri_set_smooth(m%triangles(idx), vec3_normalize(a), &
                                    vec3_normalize(c), vec3_normalize(d))
                m%triangles(idx)%color = [255, 255, 255]
            end do
        end do
        ! Bottom fan (ring j=rings-1)
        do i = 1, seg
            i2 = mod(i, seg) + 1
            a = sphere_point(radius, seg, rings, rings - 1, i)
            b = sphere_point(radius, seg, rings, rings - 1, i2)
            idx = idx + 1
            m%triangles(idx)%v = [bot, a, b]
            centroid = vec3_add(vec3_add(bot, a), b)
            m%triangles(idx)%normal = vec3_normalize(centroid)
            call tri_set_smooth(m%triangles(idx), vec3_normalize(bot), &
                                vec3_normalize(a), vec3_normalize(b))
            m%triangles(idx)%color = [255, 255, 255]
        end do
        m%num_triangles = idx
    end subroutine create_sphere

    pure function sphere_point(radius, seg, rings, j, i) result(p)
        real(dp), intent(in) :: radius
        integer, intent(in) :: seg, rings, j, i
        type(vec3) :: p
        real(dp) :: phi, theta
        phi = PI * real(j, dp) / real(rings, dp)
        theta = 2.0_dp * PI * real(i - 1, dp) / real(seg, dp)
        p = vec3_create(radius * sin(phi) * cos(theta), &
                        radius * cos(phi), &
                        radius * sin(phi) * sin(theta))
    end function sphere_point

    ! Cylinder along Y, centred at origin. Tri count = segments*2 (side)
    ! plus segments per cap when capped (so segments*4 capped).
    subroutine create_cylinder(m, radius, height, segments, capped)
        type(Mesh), intent(inout) :: m
        real(dp), intent(in) :: radius, height
        integer, intent(in) :: segments
        logical, intent(in) :: capped
        integer :: seg, i, i2, idx, total
        real(dp) :: hh, theta, theta2
        type(vec3) :: b1, b2, t1, t2, cen, centroid
        type(vec3) :: nb1, nb2

        if (allocated(m%triangles)) deallocate(m%triangles)
        seg = max(3, segments)
        hh = height * 0.5_dp
        total = seg * 2
        if (capped) total = total + seg * 2
        m%num_triangles = total
        allocate(m%triangles(total))
        idx = 0
        do i = 1, seg
            i2 = mod(i, seg) + 1
            theta = 2.0_dp * PI * real(i - 1, dp) / real(seg, dp)
            theta2 = 2.0_dp * PI * real(i2 - 1, dp) / real(seg, dp)
            b1 = vec3_create(radius * cos(theta), -hh, radius * sin(theta))
            b2 = vec3_create(radius * cos(theta2), -hh, radius * sin(theta2))
            t1 = vec3_create(radius * cos(theta), hh, radius * sin(theta))
            t2 = vec3_create(radius * cos(theta2), hh, radius * sin(theta2))
            ! Side quad, radial analytic normal from the centroid.
            ! Per-vertex side normals are the radial direction at each
            ! vertex's azimuth: (cos theta, 0, sin theta).
            nb1 = vec3_create(cos(theta), 0.0_dp, sin(theta))
            nb2 = vec3_create(cos(theta2), 0.0_dp, sin(theta2))
            idx = idx + 1
            m%triangles(idx)%v = [b1, t2, b2]
            centroid = vec3_add(vec3_add(b1, t2), b2)
            m%triangles(idx)%normal = vec3_normalize( &
                vec3_create(centroid%x, 0.0_dp, centroid%z))
            call tri_set_smooth(m%triangles(idx), nb1, nb2, nb2)
            m%triangles(idx)%color = [255, 255, 255]
            idx = idx + 1
            m%triangles(idx)%v = [b1, t1, t2]
            centroid = vec3_add(vec3_add(b1, t1), t2)
            m%triangles(idx)%normal = vec3_normalize( &
                vec3_create(centroid%x, 0.0_dp, centroid%z))
            call tri_set_smooth(m%triangles(idx), nb1, nb1, nb2)
            m%triangles(idx)%color = [255, 255, 255]
            if (capped) then
                cen = vec3_create(0.0_dp, hh, 0.0_dp)
                idx = idx + 1
                m%triangles(idx)%v = [cen, t2, t1]
                m%triangles(idx)%normal = vec3_create(0.0_dp, 1.0_dp, 0.0_dp)
                call tri_set_flat_vn(m%triangles(idx))
                m%triangles(idx)%color = [255, 255, 255]
                cen = vec3_create(0.0_dp, -hh, 0.0_dp)
                idx = idx + 1
                m%triangles(idx)%v = [cen, b1, b2]
                m%triangles(idx)%normal = vec3_create(0.0_dp, -1.0_dp, 0.0_dp)
                call tri_set_flat_vn(m%triangles(idx))
                m%triangles(idx)%color = [255, 255, 255]
            end if
        end do
        m%num_triangles = idx
    end subroutine create_cylinder

    ! Cone along Y, base at -height/2, apex at +height/2, centred at origin.
    ! Tri count = segments (side) plus segments when capped.
    subroutine create_cone(m, radius, height, segments, capped)
        type(Mesh), intent(inout) :: m
        real(dp), intent(in) :: radius, height
        integer, intent(in) :: segments
        logical, intent(in) :: capped
        integer :: seg, i, i2, idx, total
        real(dp) :: hh, theta, theta2
        type(vec3) :: b1, b2, apex, cen
        type(vec3) :: nb1, nb2, napex

        if (allocated(m%triangles)) deallocate(m%triangles)
        seg = max(3, segments)
        hh = height * 0.5_dp
        apex = vec3_create(0.0_dp, hh, 0.0_dp)
        total = seg
        if (capped) total = total + seg
        m%num_triangles = total
        allocate(m%triangles(total))
        idx = 0
        do i = 1, seg
            i2 = mod(i, seg) + 1
            theta = 2.0_dp * PI * real(i - 1, dp) / real(seg, dp)
            theta2 = 2.0_dp * PI * real(i2 - 1, dp) / real(seg, dp)
            b1 = vec3_create(radius * cos(theta), -hh, radius * sin(theta))
            b2 = vec3_create(radius * cos(theta2), -hh, radius * sin(theta2))
            ! Slant normal: for the cone surface the (unnormalised)
            ! normal at azimuth th is (h*cos(th), r, h*sin(th)).
            nb1 = vec3_normalize(vec3_create(height * cos(theta), radius, &
                                             height * sin(theta)))
            nb2 = vec3_normalize(vec3_create(height * cos(theta2), radius, &
                                             height * sin(theta2)))
            ! Apex vertex: average of the two adjacent azimuth slant
            ! normals (the slant normal of this segment), renormalised.
            napex = vec3_normalize(vec3_add(nb1, nb2))
            idx = idx + 1
            m%triangles(idx)%v = [b1, apex, b2]
            m%triangles(idx)%normal = compute_triangle_normal(b1, apex, b2)
            call tri_set_smooth(m%triangles(idx), nb1, napex, nb2)
            m%triangles(idx)%color = [255, 255, 255]
            if (capped) then
                cen = vec3_create(0.0_dp, -hh, 0.0_dp)
                idx = idx + 1
                m%triangles(idx)%v = [cen, b1, b2]
                m%triangles(idx)%normal = vec3_create(0.0_dp, -1.0_dp, 0.0_dp)
                call tri_set_flat_vn(m%triangles(idx))
                m%triangles(idx)%color = [255, 255, 255]
            end if
        end do
        m%num_triangles = idx
    end subroutine create_cone

    ! XZ plane at y=0, DOUBLE-SIDED (decision D1, WB-INV-PLANE): the
    ! front pair [a,c,b]/[a,d,c] faces +Y and the reversed-winding pair
    ! [a,b,c]/[a,c,d] faces -Y, so the winding cull keeps one pair from
    ! each side. Tri count = 4. Normals come from each triangle's
    ! winding via compute_triangle_normal (+Y, +Y, -Y, -Y).
    subroutine create_plane(m, width, depth)
        type(Mesh), intent(inout) :: m
        real(dp), intent(in) :: width, depth
        real(dp) :: hw, hd
        type(vec3) :: a, b, c, d
        integer :: i

        if (allocated(m%triangles)) deallocate(m%triangles)
        hw = width * 0.5_dp
        hd = depth * 0.5_dp
        a = vec3_create(-hw, 0.0_dp, -hd)
        b = vec3_create( hw, 0.0_dp, -hd)
        c = vec3_create( hw, 0.0_dp,  hd)
        d = vec3_create(-hw, 0.0_dp,  hd)
        m%num_triangles = 4
        allocate(m%triangles(4))
        m%triangles(1)%v = [a, c, b]
        m%triangles(2)%v = [a, d, c]
        m%triangles(3)%v = [a, b, c]
        m%triangles(4)%v = [a, c, d]
        do i = 1, 4
            m%triangles(i)%normal = compute_triangle_normal( &
                m%triangles(i)%v(1), m%triangles(i)%v(2), m%triangles(i)%v(3))
            call tri_set_flat_vn(m%triangles(i))
            m%triangles(i)%color = [255, 255, 255]
        end do
    end subroutine create_plane

    ! Square pyramid: base at -height/2, apex at +height/2.
    ! Tri count = 6 (4 sides + 2 base).
    subroutine create_pyramid(m, base, height)
        type(Mesh), intent(inout) :: m
        real(dp), intent(in) :: base, height
        real(dp) :: hb, hh
        type(vec3) :: p(4), apex
        integer :: i

        if (allocated(m%triangles)) deallocate(m%triangles)
        hb = base * 0.5_dp
        hh = height * 0.5_dp
        p(1) = vec3_create(-hb, -hh, -hb)
        p(2) = vec3_create( hb, -hh, -hb)
        p(3) = vec3_create( hb, -hh,  hb)
        p(4) = vec3_create(-hb, -hh,  hb)
        apex = vec3_create(0.0_dp, hh, 0.0_dp)
        m%num_triangles = 6
        allocate(m%triangles(6))
        m%triangles(1)%v = [p(1), apex, p(2)]
        m%triangles(2)%v = [p(2), apex, p(3)]
        m%triangles(3)%v = [p(3), apex, p(4)]
        m%triangles(4)%v = [p(4), apex, p(1)]
        m%triangles(5)%v = [p(4), p(2), p(3)]
        m%triangles(6)%v = [p(4), p(1), p(2)]
        do i = 1, 6
            m%triangles(i)%normal = compute_triangle_normal( &
                m%triangles(i)%v(1), m%triangles(i)%v(2), m%triangles(i)%v(3))
            call tri_set_flat_vn(m%triangles(i))
            m%triangles(i)%color = [255, 255, 255]
        end do
    end subroutine create_pyramid

    ! Torus around Y: radius = major radius, tube = tube radius.
    ! Tri count = segments * tube_segments * 2.
    ! Per-triangle normal is analytic: normalised (centroid - tube-centre),
    ! where the tube centre for a vertex is its major-ring centre.
    subroutine create_torus(m, radius, tube, segments, tube_segments)
        type(Mesh), intent(inout) :: m
        real(dp), intent(in) :: radius, tube
        integer, intent(in) :: segments, tube_segments
        integer :: seg, tseg, i, j, i2, j2, idx
        type(vec3) :: a, b, c, d, centroid

        if (allocated(m%triangles)) deallocate(m%triangles)
        seg = max(3, segments)
        tseg = max(3, tube_segments)
        m%num_triangles = seg * tseg * 2
        allocate(m%triangles(m%num_triangles))
        idx = 0
        do i = 1, seg
            i2 = mod(i, seg) + 1
            do j = 1, tseg
                j2 = mod(j, tseg) + 1
                a = torus_point(radius, tube, seg, tseg, i, j)
                b = torus_point(radius, tube, seg, tseg, i2, j)
                c = torus_point(radius, tube, seg, tseg, i2, j2)
                d = torus_point(radius, tube, seg, tseg, i, j2)
                idx = idx + 1
                m%triangles(idx)%v = [a, d, c]
                centroid = vec3_add(vec3_add(a, d), c)
                m%triangles(idx)%normal = torus_normal(radius, vec3_scale(centroid, 1.0_dp / 3.0_dp))
                call tri_set_smooth(m%triangles(idx), torus_normal(radius, a), &
                                    torus_normal(radius, d), torus_normal(radius, c))
                m%triangles(idx)%color = [255, 255, 255]
                idx = idx + 1
                m%triangles(idx)%v = [a, c, b]
                centroid = vec3_add(vec3_add(a, c), b)
                m%triangles(idx)%normal = torus_normal(radius, vec3_scale(centroid, 1.0_dp / 3.0_dp))
                call tri_set_smooth(m%triangles(idx), torus_normal(radius, a), &
                                    torus_normal(radius, c), torus_normal(radius, b))
                m%triangles(idx)%color = [255, 255, 255]
            end do
        end do
        m%num_triangles = idx
    end subroutine create_torus

    pure function torus_point(radius, tube, seg, tseg, i, j) result(p)
        real(dp), intent(in) :: radius, tube
        integer, intent(in) :: seg, tseg, i, j
        type(vec3) :: p
        real(dp) :: theta, phi, rr
        theta = 2.0_dp * PI * real(i - 1, dp) / real(seg, dp)
        phi = 2.0_dp * PI * real(j - 1, dp) / real(tseg, dp)
        rr = radius + tube * cos(phi)
        p = vec3_create(rr * cos(theta), tube * sin(phi), rr * sin(theta))
    end function torus_point

    pure function torus_normal(radius, p) result(n)
        real(dp), intent(in) :: radius
        type(vec3), intent(in) :: p
        type(vec3) :: n, centre
        real(dp) :: rl
        rl = sqrt(p%x * p%x + p%z * p%z)
        if (rl > 1.0e-12_dp) then
            centre = vec3_create(radius * p%x / rl, 0.0_dp, radius * p%z / rl)
        else
            centre = vec3_create(radius, 0.0_dp, 0.0_dp)
        end if
        n = vec3_normalize(vec3_sub(p, centre))
    end function torus_normal

    subroutine mesh_append(dst, src)
        type(Mesh), intent(inout) :: dst
        type(Mesh), intent(in) :: src
        type(Triangle), allocatable :: tmp(:)
        integer :: old_n

        if (src%num_triangles <= 0) return
        if (.not. allocated(dst%triangles) .or. dst%num_triangles <= 0) then
            if (allocated(dst%triangles)) deallocate(dst%triangles)
            allocate(dst%triangles(src%num_triangles))
            dst%triangles = src%triangles(1:src%num_triangles)
            dst%num_triangles = src%num_triangles
            return
        end if
        old_n = dst%num_triangles
        allocate(tmp(old_n + src%num_triangles))
        tmp(1:old_n) = dst%triangles(1:old_n)
        tmp(old_n + 1:old_n + src%num_triangles) = src%triangles(1:src%num_triangles)
        call move_alloc(tmp, dst%triangles)
        dst%num_triangles = old_n + src%num_triangles
    end subroutine mesh_append

    subroutine mesh_add_transformed(dst, src, model, use_color, rgb, material_id)
        type(Mesh), intent(inout) :: dst
        type(Mesh), intent(in) :: src
        type(mat4), intent(in) :: model
        logical, intent(in) :: use_color
        integer, intent(in) :: rgb(3), material_id
        type(Triangle), allocatable :: tmp(:)
        type(Triangle) :: t
        type(vec3) :: swap_v
        integer :: old_n, i, k
        logical :: flip

        if (src%num_triangles <= 0) return
        ! Negative-determinant model (reflection, or an odd number of
        ! negative scale axes) reverses triangle winding.  Swapping
        ! vertices 2/3 (and their vertex normals) after the transform
        ! restores the original orientation, so the face normal
        ! recomputed from winding below matches the unmirrored
        ! convention.  det >= 0 takes exactly the pre-P3 path.
        flip = mat4_determinant(model) < 0.0_dp
        if (allocated(dst%triangles) .and. dst%num_triangles > 0) then
            old_n = dst%num_triangles
        else
            old_n = 0
        end if
        allocate(tmp(old_n + src%num_triangles))
        if (old_n > 0) tmp(1:old_n) = dst%triangles(1:old_n)
        do i = 1, src%num_triangles
            t = src%triangles(i)
            do k = 1, 3
                t%v(k) = mat4_transform_vec3(model, src%triangles(i)%v(k), .true.)
            end do
            if (flip) then
                swap_v = t%v(2); t%v(2) = t%v(3); t%v(3) = swap_v
            end if
            t%normal = compute_triangle_normal(t%v(1), t%v(2), t%v(3))
            if (t%smooth) then
                ! Vertex normals transform as DIRECTIONS (is_point=.false.:
                ! no translation, no w divide), then renormalise.
                do k = 1, 3
                    t%vn(k) = vec3_normalize(mat4_transform_vec3( &
                        model, src%triangles(i)%vn(k), .false.))
                end do
                if (flip) then
                    swap_v = t%vn(2); t%vn(2) = t%vn(3); t%vn(3) = swap_v
                end if
            else
                ! Flat: vn follows the transformed face normal.
                call tri_set_flat_vn(t)
            end if
            if (use_color) then
                t%color = rgb
            else
                t%color = src%triangles(i)%color
            end if
            t%material_id = material_id
            tmp(old_n + i) = t
        end do
        if (allocated(dst%triangles)) deallocate(dst%triangles)
        call move_alloc(tmp, dst%triangles)
        dst%num_triangles = old_n + src%num_triangles
    end subroutine mesh_add_transformed

    subroutine export_mesh_json(m, filename)
        type(Mesh), intent(in) :: m
        character(len=*), intent(in) :: filename
        integer :: u, i

        open(newunit=u, file=filename, status='replace', action='write')
        write(u, '(A)') '{'
        write(u, '(A)') '  "triangles": ['
        do i = 1, m%num_triangles
            write(u, '(A,I0,A)') '    {"id": ', i, ','
            write(u, '(A,F8.3,A,F8.3,A,F8.3,A,F8.3,A,F8.3,A,F8.3,A,F8.3,A,F8.3,A,F8.3,A)') &
                '     "v": [[', &
                m%triangles(i)%v(1)%x, ',', m%triangles(i)%v(1)%y, ',', m%triangles(i)%v(1)%z, '],[', &
                m%triangles(i)%v(2)%x, ',', m%triangles(i)%v(2)%y, ',', m%triangles(i)%v(2)%z, '],[', &
                m%triangles(i)%v(3)%x, ',', m%triangles(i)%v(3)%y, ',', m%triangles(i)%v(3)%z, ']],'
            write(u, '(A,I3,A,I3,A,I3,A)') &
                '     "color": [', &
                m%triangles(i)%color(1), ',', m%triangles(i)%color(2), ',', m%triangles(i)%color(3), ']}'
            if (i < m%num_triangles) then
                write(u, '(A)') ','
            else
                write(u, '(A)') ''
            end if
        end do
        write(u, '(A)') '  ]'
        write(u, '(A)') '}'
        close(u)
    end subroutine export_mesh_json

    subroutine export_mesh_obj(m, filename)
        type(Mesh), intent(in) :: m
        character(len=*), intent(in) :: filename
        integer :: u, i

        open(newunit=u, file=filename, status='replace', action='write')
        write(u, '(A)') '# Fortran 3D Engine OBJ Export'
        do i = 1, m%num_triangles
            write(u, '(A,3(1X,F9.4))') 'v', m%triangles(i)%v(1)%x, m%triangles(i)%v(1)%y, m%triangles(i)%v(1)%z
            write(u, '(A,3(1X,F9.4))') 'v', m%triangles(i)%v(2)%x, m%triangles(i)%v(2)%y, m%triangles(i)%v(2)%z
            write(u, '(A,3(1X,F9.4))') 'v', m%triangles(i)%v(3)%x, m%triangles(i)%v(3)%y, m%triangles(i)%v(3)%z
        end do
        do i = 1, m%num_triangles
            write(u, '(A,3(1X,I0))') 'f', (i-1)*3+1, (i-1)*3+2, (i-1)*3+3
        end do
        close(u)
    end subroutine export_mesh_obj

end module mesh_3d
