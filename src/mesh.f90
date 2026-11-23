module mesh_3d
    use math_3d
    use mesh_data_3d
    implicit none
    private
    public :: Triangle, Mesh, create_cube, compute_triangle_normal, export_mesh_json, export_mesh_obj, &
              free_mesh, create_box, create_sphere, create_cylinder, create_cone, &
              create_plane, create_pyramid, create_torus, mesh_append, mesh_add_transformed, &
              tri_set_smooth, &
              mesh_data_to_triangles, &
              build_cube_data, build_box_data, build_sphere_data, &
              build_cylinder_data, build_cone_data, build_plane_data, &
              build_pyramid_data, build_torus_data

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
        ! Per-corner UVs (v3.0 Phase 1, G1): uv(:, i) corresponds to
        ! v(i).  Builder-produced triangles carry the REAL UVs of the
        ! indexed mesh_data they were built from (see
        ! mesh_data_to_triangles); triangles built by hand keep the
        ! zero default.  The legacy renderer still synthesises UVs via
        ! texture_3d's prim_uv (renderer_3d is outside Phase 1's mesh
        ! ownership); this field is the data the Phase 2 renderer
        ! switch will consume.
        real(dp) :: uv(2, 3) = 0.0_dp
    end type Triangle

    type :: Mesh
        integer :: num_triangles = 0
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

    ! -----------------------------------------------------------------
    ! Phase 1 (G1): indexed mesh_data -> legacy Triangle soup shim.
    !
    ! Expands md%idx into the unindexed soup the legacy renderer
    ! consumes.  Corner positions / vertex normals / per-triangle
    ! normals come from the dp shadow arrays when the builder filled
    ! them (bit-identical to the pre-Phase-1 builders -- see the
    ! mesh_data_3d header for why the shadow exists), otherwise from
    ! the real32 arrays.  Corner UVs ALWAYS come from md%uv: builder
    ! paths no longer need texture_3d's prim_uv synthesis.  Flat
    ! triangles get vn == face normal (the tri_set_flat_vn invariant);
    ! smooth triangles get the stored vertex normals.
    ! -----------------------------------------------------------------
    subroutine mesh_data_to_triangles(md, m)
        type(mesh_data), intent(in) :: md
        type(Mesh), intent(inout) :: m
        integer :: t, k, vi
        logical :: have_pos_dp, have_nrm_dp, have_tn_dp, have_nrm
        logical :: have_uv, have_col, have_smooth
        type(vec3) :: vv(3), nn(3), tn

        if (allocated(m%triangles)) deallocate(m%triangles)
        m%num_triangles = md%n_tris
        if (md%n_tris <= 0 .or. .not. allocated(md%idx)) then
            m%num_triangles = 0
            return
        end if
        allocate(m%triangles(md%n_tris))
        have_pos_dp = allocated(md%pos_dp)
        have_nrm_dp = allocated(md%nrm_dp)
        have_tn_dp = allocated(md%tnrm_dp)
        have_nrm = allocated(md%nrm)
        have_uv = allocated(md%uv)
        have_col = allocated(md%col)
        have_smooth = allocated(md%smooth_tri)
        do t = 1, md%n_tris
            do k = 1, 3
                vi = md%idx(k, t)
                if (have_pos_dp) then
                    vv(k) = vec3_create(md%pos_dp(1, vi), &
                                        md%pos_dp(2, vi), &
                                        md%pos_dp(3, vi))
                else
                    vv(k) = vec3_create(real(md%pos(1, vi), dp), &
                                        real(md%pos(2, vi), dp), &
                                        real(md%pos(3, vi), dp))
                end if
                if (have_nrm_dp) then
                    nn(k) = vec3_create(md%nrm_dp(1, vi), &
                                        md%nrm_dp(2, vi), &
                                        md%nrm_dp(3, vi))
                else if (have_nrm) then
                    nn(k) = vec3_create(real(md%nrm(1, vi), dp), &
                                        real(md%nrm(2, vi), dp), &
                                        real(md%nrm(3, vi), dp))
                else
                    nn(k) = vec3_create(0.0_dp, 0.0_dp, 0.0_dp)
                end if
                if (have_uv) then
                    m%triangles(t)%uv(:, k) = real(md%uv(:, vi), dp)
                else
                    m%triangles(t)%uv(:, k) = 0.0_dp
                end if
            end do
            m%triangles(t)%v = vv
            if (have_tn_dp) then
                tn = vec3_create(md%tnrm_dp(1, t), md%tnrm_dp(2, t), &
                                 md%tnrm_dp(3, t))
            else
                tn = compute_triangle_normal(vv(1), vv(2), vv(3))
            end if
            m%triangles(t)%normal = tn
            if (have_smooth .and. md%smooth_tri(t) .and. &
                (have_nrm .or. have_nrm_dp)) then
                m%triangles(t)%smooth = .true.
                m%triangles(t)%vn = nn
            else
                m%triangles(t)%smooth = .false.
                m%triangles(t)%vn = [tn, tn, tn]
            end if
            if (have_col) then
                m%triangles(t)%color = md%col(:, t)
            else
                m%triangles(t)%color = [255, 255, 255]
            end if
            m%triangles(t)%material_id = 0
        end do
    end subroutine mesh_data_to_triangles

    ! -----------------------------------------------------------------
    ! Indexed builders (Phase 1).  Each build_<name>_data returns a
    ! mesh_data with shared vertices and real UVs; each legacy
    ! create_<name> below is exactly build_<name>_data +
    ! mesh_data_to_triangles, so the soup (positions, normals, vertex
    ! normals, colours, triangle order) is bit-identical to the
    ! pre-Phase-1 builders.
    ! -----------------------------------------------------------------

    ! Shared box core for cube / box: 24 verts (6 faces x 4, split per
    ! face for per-face normals + per-face UVs), 12 tris, face order
    ! and colours exactly as the legacy soup: -Z red, +X green,
    ! +Z blue, -X yellow, +Y magenta, -Y cyan.
    subroutine build_box_data(md, sx, sy, sz)
        type(mesh_data), intent(out) :: md
        real(dp), intent(in) :: sx, sy, sz
        real(dp) :: hx, hy, hz, ext(3)
        type(vec3) :: p(8), fn
        integer :: q(4, 6), ax(6), sg(6), fc(3, 6)
        integer :: f, base, t
        integer :: i

        hx = sx * 0.5_dp
        hy = sy * 0.5_dp
        hz = sz * 0.5_dp
        ext = [sx, sy, sz]
        p(1) = vec3_create(-hx, -hy, -hz)
        p(2) = vec3_create( hx, -hy, -hz)
        p(3) = vec3_create( hx,  hy, -hz)
        p(4) = vec3_create(-hx,  hy, -hz)
        p(5) = vec3_create(-hx, -hy,  hz)
        p(6) = vec3_create( hx, -hy,  hz)
        p(7) = vec3_create( hx,  hy,  hz)
        p(8) = vec3_create(-hx,  hy,  hz)
        ! Per-face quad corners q(1..4): legacy tris are
        ! [q1,q3,q2] and [q1,q4,q3] on every face.
        q(:, 1) = [1, 2, 3, 4]   ! -Z
        q(:, 2) = [2, 6, 7, 3]   ! +X
        q(:, 3) = [6, 5, 8, 7]   ! +Z
        q(:, 4) = [5, 1, 4, 8]   ! -X
        q(:, 5) = [4, 3, 7, 8]   ! +Y
        q(:, 6) = [5, 6, 2, 1]   ! -Y
        ax = [3, 1, 3, 1, 2, 2]
        sg = [-1, 1, 1, -1, 1, -1]
        fc(:, 1) = [220, 60, 60]
        fc(:, 2) = [60, 220, 60]
        fc(:, 3) = [60, 100, 240]
        fc(:, 4) = [240, 220, 50]
        fc(:, 5) = [200, 80, 220]
        fc(:, 6) = [60, 220, 220]

        call mesh_data_alloc(md, 24, 12)
        t = 0
        do f = 1, 6
            base = (f - 1) * 4
            fn = compute_triangle_normal(p(q(1, f)), p(q(3, f)), &
                                         p(q(2, f)))
            do i = 1, 4
                call mesh_data_put_vertex(md, base + i, p(q(i, f)), fn, &
                    mesh_data_face_uv(p(q(i, f)), ext, ax(f), sg(f)))
            end do
            t = t + 1
            call mesh_data_put_tri(md, t, base + 1, base + 3, base + 2, &
                                   fn, .false., fc(:, f))
            t = t + 1
            call mesh_data_put_tri(md, t, base + 1, base + 4, base + 3, &
                                   fn, .false., fc(:, f))
        end do
        call mesh_data_finalize(md)
    end subroutine build_box_data

    subroutine build_cube_data(md, size)
        type(mesh_data), intent(out) :: md
        real(dp), intent(in) :: size
        call build_box_data(md, size, size, size)
    end subroutine build_cube_data

    subroutine create_cube(m, size)
        type(Mesh), intent(inout) :: m
        real(dp), intent(in) :: size
        type(mesh_data) :: md
        call build_cube_data(md, size)
        call mesh_data_to_triangles(md, m)
        call mesh_data_free(md)
    end subroutine create_cube

    subroutine create_box(m, sx, sy, sz)
        type(Mesh), intent(inout) :: m
        real(dp), intent(in) :: sx, sy, sz
        type(mesh_data) :: md
        call build_box_data(md, sx, sy, sz)
        call mesh_data_to_triangles(md, m)
        call mesh_data_free(md)
    end subroutine create_box

    ! UV sphere, indexed: 2*seg pole vertices (one per fan segment --
    ! a pole has no single UV) + (rings-1) rings of seg+1 vertices
    ! (the +1 is the UV-seam duplicate: same position/normal as the
    ! ring's first vertex, u = 1 instead of 0).
    !   n_verts = 2*seg + (rings-1)*(seg+1)
    !   n_tris  = 2*seg*(rings-1)   (same count as the legacy soup)
    ! UV: u = (i-1)/seg around the equator, v = j/rings pole to pole
    ! (v = 0 at the +Y pole, matching the prim_uv sphere contract's
    ! v; u differs from prim_uv by its +0.5 phase -- prim_uv wraps
    ! through the sampler, the indexed UV is the canonical [0,1]
    ! sweep with a proper seam).
    ! Vertex normals are analytic: normalize(position).
    subroutine build_sphere_data(md, radius, segments)
        type(mesh_data), intent(out) :: md
        real(dp), intent(in) :: radius
        integer, intent(in) :: segments
        integer :: seg, rings, i, j, t, nv
        integer :: pole_t, pole_b, rb
        type(vec3) :: top, bot, a, b, c, d, centroid

        seg = max(3, segments)
        rings = max(2, (seg * 3) / 4)
        nv = 2 * seg + (rings - 1) * (seg + 1)
        call mesh_data_alloc(md, nv, seg * (rings - 1) * 2)
        top = vec3_create(0.0_dp, radius, 0.0_dp)
        bot = vec3_create(0.0_dp, -radius, 0.0_dp)
        ! Pole duplicates.
        do i = 1, seg
            call mesh_data_put_vertex(md, i, top, &
                vec3_create(0.0_dp, 1.0_dp, 0.0_dp), &
                [real(i, dp) - 0.5_dp, 0.0_dp] / &
                [real(seg, dp), 1.0_dp])
            pole_b = seg + (rings - 1) * (seg + 1) + i
            call mesh_data_put_vertex(md, pole_b, bot, &
                vec3_create(0.0_dp, -1.0_dp, 0.0_dp), &
                [real(i, dp) - 0.5_dp, 1.0_dp] / &
                [real(seg, dp), 1.0_dp])
        end do
        ! Rings j = 1..rings-1, vertices i = 1..seg+1 (seam dup last).
        do j = 1, rings - 1
            rb = seg + (j - 1) * (seg + 1)
            do i = 1, seg + 1
                a = sphere_point(radius, seg, rings, j, &
                                 mod(i - 1, seg) + 1)
                call mesh_data_put_vertex(md, rb + i, a, &
                    vec3_normalize(a), &
                    [real(i - 1, dp) / real(seg, dp), &
                     real(j, dp) / real(rings, dp)])
            end do
        end do
        t = 0
        ! Top fan (ring j=1): legacy tri [top, b, a]; ring vertex k of
        ! ring j lives at seg + (j-1)*(seg+1) + k, so ring 1 vertex k
        ! is at seg + k and the seam-aware "next" vertex is k+1.
        do i = 1, seg
            a = sphere_point(radius, seg, rings, 1, i)
            b = sphere_point(radius, seg, rings, 1, mod(i, seg) + 1)
            centroid = vec3_add(vec3_add(top, b), a)
            t = t + 1
            call mesh_data_put_tri(md, t, i, seg + i + 1, seg + i, &
                                   vec3_normalize(centroid), .true., &
                                   [255, 255, 255])
        end do
        ! Middle bands j=1..rings-2.
        do j = 1, rings - 2
            do i = 1, seg
                a = sphere_point(radius, seg, rings, j, i)
                b = sphere_point(radius, seg, rings, j, mod(i, seg) + 1)
                c = sphere_point(radius, seg, rings, j + 1, mod(i, seg) + 1)
                d = sphere_point(radius, seg, rings, j + 1, i)
                rb = seg + (j - 1) * (seg + 1)
                t = t + 1
                centroid = vec3_add(vec3_add(a, b), c)
                call mesh_data_put_tri(md, t, rb + i, rb + i + 1, &
                    rb + (seg + 1) + i + 1, vec3_normalize(centroid), &
                    .true., [255, 255, 255])
                t = t + 1
                centroid = vec3_add(vec3_add(a, c), d)
                call mesh_data_put_tri(md, t, rb + i, &
                    rb + (seg + 1) + i + 1, rb + (seg + 1) + i, &
                    vec3_normalize(centroid), .true., [255, 255, 255])
            end do
        end do
        ! Bottom fan (ring j=rings-1).
        pole_t = seg + (rings - 1) * (seg + 1)
        rb = seg + (rings - 2) * (seg + 1)
        do i = 1, seg
            a = sphere_point(radius, seg, rings, rings - 1, i)
            b = sphere_point(radius, seg, rings, rings - 1, &
                             mod(i, seg) + 1)
            centroid = vec3_add(vec3_add(bot, a), b)
            t = t + 1
            call mesh_data_put_tri(md, t, pole_t + i, rb + i, rb + i + 1, &
                                   vec3_normalize(centroid), .true., &
                                   [255, 255, 255])
        end do
        call mesh_data_finalize(md)
    end subroutine build_sphere_data

    subroutine create_sphere(m, radius, segments)
        type(Mesh), intent(inout) :: m
        real(dp), intent(in) :: radius
        integer, intent(in) :: segments
        type(mesh_data) :: md
        call build_sphere_data(md, radius, segments)
        call mesh_data_to_triangles(md, m)
        call mesh_data_free(md)
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

    ! Cylinder along Y, indexed.  Side: 2 rows (bottom/top) of seg+1
    ! verts (seam duplicate last).  Each cap: 1 centre + seg+1 ring
    ! verts (split from the side rows: cap verts carry the flat cap
    ! normal and planar disc UVs).
    !   n_verts = 2*(seg+1)          uncapped
    !             2*(seg+1)+2*(seg+2) capped
    !   n_tris  = 2*seg (side) + 2*seg (caps, when capped)
    ! Side UV: u = (i-1)/seg, v = 0 bottom / 1 top (the prim_uv
    ! cylinder contract's v).  Side normals: analytic radial.
    subroutine build_cylinder_data(md, radius, height, segments, capped)
        type(mesh_data), intent(out) :: md
        real(dp), intent(in) :: radius, height
        integer, intent(in) :: segments
        logical, intent(in) :: capped
        integer :: seg, i, t, nv, bot_r, top_r, cen_t, cen_b, cap_t, cap_b
        real(dp) :: hh, theta, theta2
        type(vec3) :: b1, b2, t1, t2, centroid, nb

        seg = max(3, segments)
        hh = height * 0.5_dp
        cen_t = 0; cap_t = 0; cen_b = 0; cap_b = 0
        nv = 2 * (seg + 1)
        if (capped) nv = nv + 2 * (seg + 2)
        call mesh_data_alloc(md, nv, seg * 2 + merge(seg * 2, 0, capped))
        bot_r = 0
        top_r = seg + 1
        do i = 1, seg + 1
            theta = 2.0_dp * PI * real(mod(i - 1, seg), dp) / real(seg, dp)
            nb = vec3_create(cos(theta), 0.0_dp, sin(theta))
            b1 = vec3_create(radius * cos(theta), -hh, radius * sin(theta))
            t1 = vec3_create(radius * cos(theta), hh, radius * sin(theta))
            call mesh_data_put_vertex(md, bot_r + i, b1, nb, &
                [real(i - 1, dp) / real(seg, dp), 0.0_dp])
            call mesh_data_put_vertex(md, top_r + i, t1, nb, &
                [real(i - 1, dp) / real(seg, dp), 1.0_dp])
        end do
        if (capped) then
            cen_t = 2 * (seg + 1) + 1
            cap_t = cen_t + 1
            cen_b = cap_t + seg + 1
            cap_b = cen_b + 1
            call mesh_data_put_vertex(md, cen_t, &
                vec3_create(0.0_dp, hh, 0.0_dp), &
                vec3_create(0.0_dp, 1.0_dp, 0.0_dp), [0.5_dp, 0.5_dp])
            call mesh_data_put_vertex(md, cen_b, &
                vec3_create(0.0_dp, -hh, 0.0_dp), &
                vec3_create(0.0_dp, -1.0_dp, 0.0_dp), [0.5_dp, 0.5_dp])
            do i = 1, seg + 1
                theta = 2.0_dp * PI * real(mod(i - 1, seg), dp) / &
                        real(seg, dp)
                t1 = vec3_create(radius * cos(theta), hh, &
                                 radius * sin(theta))
                b1 = vec3_create(radius * cos(theta), -hh, &
                                 radius * sin(theta))
                call mesh_data_put_vertex(md, cap_t + i - 1, t1, &
                    vec3_create(0.0_dp, 1.0_dp, 0.0_dp), &
                    [t1%x / (2.0_dp * radius) + 0.5_dp, &
                     t1%z / (2.0_dp * radius) + 0.5_dp])
                call mesh_data_put_vertex(md, cap_b + i - 1, b1, &
                    vec3_create(0.0_dp, -1.0_dp, 0.0_dp), &
                    [b1%x / (2.0_dp * radius) + 0.5_dp, &
                     b1%z / (2.0_dp * radius) + 0.5_dp])
            end do
        end if
        t = 0
        do i = 1, seg
            ! Exact legacy corner points for the analytic
            ! per-triangle normals (centroid-based, as pre-Phase-1).
            theta = 2.0_dp * PI * real(i - 1, dp) / real(seg, dp)
            theta2 = 2.0_dp * PI * real(mod(i, seg), dp) / real(seg, dp)
            b1 = vec3_create(radius * cos(theta), -hh, radius * sin(theta))
            b2 = vec3_create(radius * cos(theta2), -hh, &
                             radius * sin(theta2))
            t1 = vec3_create(radius * cos(theta), hh, radius * sin(theta))
            t2 = vec3_create(radius * cos(theta2), hh, &
                             radius * sin(theta2))
            t = t + 1
            centroid = vec3_add(vec3_add(b1, t2), b2)
            call mesh_data_put_tri(md, t, bot_r + i, top_r + i + 1, &
                bot_r + i + 1, &
                vec3_normalize(vec3_create(centroid%x, 0.0_dp, &
                                           centroid%z)), &
                .true., [255, 255, 255])
            t = t + 1
            centroid = vec3_add(vec3_add(b1, t1), t2)
            call mesh_data_put_tri(md, t, bot_r + i, top_r + i, &
                top_r + i + 1, &
                vec3_normalize(vec3_create(centroid%x, 0.0_dp, &
                                           centroid%z)), &
                .true., [255, 255, 255])
            if (capped) then
                t = t + 1
                call mesh_data_put_tri(md, t, cen_t, cap_t + i, &
                    cap_t + i - 1, vec3_create(0.0_dp, 1.0_dp, 0.0_dp), &
                    .false., [255, 255, 255])
                t = t + 1
                call mesh_data_put_tri(md, t, cen_b, cap_b + i - 1, &
                    cap_b + i, vec3_create(0.0_dp, -1.0_dp, 0.0_dp), &
                    .false., [255, 255, 255])
            end if
        end do
        call mesh_data_finalize(md)
    end subroutine build_cylinder_data

    subroutine create_cylinder(m, radius, height, segments, capped)
        type(Mesh), intent(inout) :: m
        real(dp), intent(in) :: radius, height
        integer, intent(in) :: segments
        logical, intent(in) :: capped
        type(mesh_data) :: md
        call build_cylinder_data(md, radius, height, segments, capped)
        call mesh_data_to_triangles(md, m)
        call mesh_data_free(md)
    end subroutine create_cylinder

    ! Cone along Y, indexed: base ring of seg+1 verts (seam dup),
    ! seg apex duplicates (the apex vertex normal is the average of
    ! the two adjacent slant normals, so it differs per segment), and
    ! when capped a split cap centre + ring of seg+1.
    !   n_verts = (seg+1) + seg = 2*seg+1        uncapped
    !             3*seg+3                        capped
    !   n_tris  = seg (side) + seg (cap, when capped)
    ! Side UV: u = (i-1)/seg, v = 0 at the base, 1 at the apex.
    subroutine build_cone_data(md, radius, height, segments, capped)
        type(mesh_data), intent(out) :: md
        real(dp), intent(in) :: radius, height
        integer, intent(in) :: segments
        logical, intent(in) :: capped
        integer :: seg, i, t, nv, apex_r, cen_b, cap_b
        real(dp) :: hh, theta, theta2
        type(vec3) :: b1, b2, apex, nb1, nb2

        seg = max(3, segments)
        hh = height * 0.5_dp
        apex = vec3_create(0.0_dp, hh, 0.0_dp)
        cen_b = 0; cap_b = 0
        nv = (seg + 1) + seg
        if (capped) nv = nv + seg + 2
        call mesh_data_alloc(md, nv, seg + merge(seg, 0, capped))
        do i = 1, seg + 1
            theta = 2.0_dp * PI * real(mod(i - 1, seg), dp) / real(seg, dp)
            b1 = vec3_create(radius * cos(theta), -hh, radius * sin(theta))
            nb1 = vec3_normalize(vec3_create(height * cos(theta), radius, &
                                             height * sin(theta)))
            call mesh_data_put_vertex(md, i, b1, nb1, &
                [real(i - 1, dp) / real(seg, dp), 0.0_dp])
        end do
        apex_r = seg + 1
        do i = 1, seg
            theta = 2.0_dp * PI * real(i - 1, dp) / real(seg, dp)
            theta2 = 2.0_dp * PI * real(mod(i, seg), dp) / real(seg, dp)
            nb1 = vec3_normalize(vec3_create(height * cos(theta), radius, &
                                             height * sin(theta)))
            nb2 = vec3_normalize(vec3_create(height * cos(theta2), radius, &
                                             height * sin(theta2)))
            call mesh_data_put_vertex(md, apex_r + i, apex, &
                vec3_normalize(vec3_add(nb1, nb2)), &
                [(real(i, dp) - 0.5_dp) / real(seg, dp), 1.0_dp])
        end do
        if (capped) then
            cen_b = apex_r + seg + 1
            cap_b = cen_b + 1
            call mesh_data_put_vertex(md, cen_b, &
                vec3_create(0.0_dp, -hh, 0.0_dp), &
                vec3_create(0.0_dp, -1.0_dp, 0.0_dp), [0.5_dp, 0.5_dp])
            do i = 1, seg + 1
                theta = 2.0_dp * PI * real(mod(i - 1, seg), dp) / &
                        real(seg, dp)
                b1 = vec3_create(radius * cos(theta), -hh, &
                                 radius * sin(theta))
                call mesh_data_put_vertex(md, cap_b + i - 1, b1, &
                    vec3_create(0.0_dp, -1.0_dp, 0.0_dp), &
                    [b1%x / (2.0_dp * radius) + 0.5_dp, &
                     b1%z / (2.0_dp * radius) + 0.5_dp])
            end do
        end if
        t = 0
        do i = 1, seg
            theta = 2.0_dp * PI * real(i - 1, dp) / real(seg, dp)
            theta2 = 2.0_dp * PI * real(mod(i, seg), dp) / real(seg, dp)
            b1 = vec3_create(radius * cos(theta), -hh, radius * sin(theta))
            b2 = vec3_create(radius * cos(theta2), -hh, &
                             radius * sin(theta2))
            t = t + 1
            call mesh_data_put_tri(md, t, i, apex_r + i, i + 1, &
                compute_triangle_normal(b1, apex, b2), .true., &
                [255, 255, 255])
            if (capped) then
                t = t + 1
                call mesh_data_put_tri(md, t, cen_b, cap_b + i - 1, &
                    cap_b + i, vec3_create(0.0_dp, -1.0_dp, 0.0_dp), &
                    .false., [255, 255, 255])
            end if
        end do
        call mesh_data_finalize(md)
    end subroutine build_cone_data

    subroutine create_cone(m, radius, height, segments, capped)
        type(Mesh), intent(inout) :: m
        real(dp), intent(in) :: radius, height
        integer, intent(in) :: segments
        logical, intent(in) :: capped
        type(mesh_data) :: md
        call build_cone_data(md, radius, height, segments, capped)
        call mesh_data_to_triangles(md, m)
        call mesh_data_free(md)
    end subroutine create_cone

    ! XZ plane at y=0, indexed: TWO indexed quads (front +Y and back
    ! -Y), 4 verts each -- the legacy plane is double-sided with
    ! opposite normals per side, which a single shared quad cannot
    ! carry in per-vertex normals, so the two sides split vertices.
    ! This is the data-side fix for the old "4-triangle plane
    ! workaround": each side is now one indexed quad (2 tris, shared
    ! verts), not soup.
    !   n_verts = 8, n_tris = 4.  UV: the prim_uv plane contract --
    !   (-w/2,-d/2) = (0,0), (+w/2,+d/2) = (1,1).
    subroutine build_plane_data(md, width, depth)
        type(mesh_data), intent(out) :: md
        real(dp), intent(in) :: width, depth
        real(dp) :: hw, hd
        type(vec3) :: a, b, c, d, up, dn
        integer :: t

        hw = width * 0.5_dp
        hd = depth * 0.5_dp
        a = vec3_create(-hw, 0.0_dp, -hd)
        b = vec3_create( hw, 0.0_dp, -hd)
        c = vec3_create( hw, 0.0_dp,  hd)
        d = vec3_create(-hw, 0.0_dp,  hd)
        up = vec3_create(0.0_dp, 1.0_dp, 0.0_dp)
        dn = vec3_create(0.0_dp, -1.0_dp, 0.0_dp)
        call mesh_data_alloc(md, 8, 4)
        call mesh_data_put_vertex(md, 1, a, up, [0.0_dp, 0.0_dp])
        call mesh_data_put_vertex(md, 2, b, up, [1.0_dp, 0.0_dp])
        call mesh_data_put_vertex(md, 3, c, up, [1.0_dp, 1.0_dp])
        call mesh_data_put_vertex(md, 4, d, up, [0.0_dp, 1.0_dp])
        call mesh_data_put_vertex(md, 5, a, dn, [0.0_dp, 0.0_dp])
        call mesh_data_put_vertex(md, 6, b, dn, [1.0_dp, 0.0_dp])
        call mesh_data_put_vertex(md, 7, c, dn, [1.0_dp, 1.0_dp])
        call mesh_data_put_vertex(md, 8, d, dn, [0.0_dp, 1.0_dp])
        t = 0
        t = t + 1
        call mesh_data_put_tri(md, t, 1, 3, 2, &
            compute_triangle_normal(a, c, b), .false., [255, 255, 255])
        t = t + 1
        call mesh_data_put_tri(md, t, 1, 4, 3, &
            compute_triangle_normal(a, d, c), .false., [255, 255, 255])
        t = t + 1
        call mesh_data_put_tri(md, t, 5, 6, 7, &
            compute_triangle_normal(a, b, c), .false., [255, 255, 255])
        t = t + 1
        call mesh_data_put_tri(md, t, 5, 7, 8, &
            compute_triangle_normal(a, c, d), .false., [255, 255, 255])
        call mesh_data_finalize(md)
    end subroutine build_plane_data

    subroutine create_plane(m, width, depth)
        type(Mesh), intent(inout) :: m
        real(dp), intent(in) :: width, depth
        type(mesh_data) :: md
        call build_plane_data(md, width, depth)
        call mesh_data_to_triangles(md, m)
        call mesh_data_free(md)
    end subroutine create_plane

    ! Square pyramid, indexed, flat-shaded: each of the 4 side faces
    ! splits its 3 verts (the apex is duplicated per face), the base
    ! quad splits its 4.
    !   n_verts = 4*3 + 4 = 16, n_tris = 6 (4 sides + 2 base).
    ! UV: per-face planar projection (mesh_data_face_uv with the
    ! face's dominant axis, extents (base, height, base)) -- the
    ! prim_uv pyramid contract.
    subroutine build_pyramid_data(md, base, height)
        type(mesh_data), intent(out) :: md
        real(dp), intent(in) :: base, height
        real(dp) :: hb, hh, ext(3)
        type(vec3) :: p(4), apex, fn, fv(3)
        integer :: f, t, vb, ax, sg, vi
        integer :: nxt(4)

        hb = base * 0.5_dp
        hh = height * 0.5_dp
        ext = [base, height, base]
        p(1) = vec3_create(-hb, -hh, -hb)
        p(2) = vec3_create( hb, -hh, -hb)
        p(3) = vec3_create( hb, -hh,  hb)
        p(4) = vec3_create(-hb, -hh,  hb)
        apex = vec3_create(0.0_dp, hh, 0.0_dp)
        nxt = [2, 3, 4, 1]
        call mesh_data_alloc(md, 16, 6)
        t = 0
        do f = 1, 4
            vb = (f - 1) * 3
            fn = compute_triangle_normal(p(f), apex, p(nxt(f)))
            if (abs(fn%x) >= abs(fn%y) .and. abs(fn%x) >= abs(fn%z)) then
                ax = 1
                sg = 1
                if (fn%x < 0.0_dp) sg = -1
            else if (abs(fn%y) >= abs(fn%z)) then
                ax = 2
                sg = 1
                if (fn%y < 0.0_dp) sg = -1
            else
                ax = 3
                sg = 1
                if (fn%z < 0.0_dp) sg = -1
            end if
            fv(1) = p(f)
            fv(2) = apex
            fv(3) = p(nxt(f))
            do vi = 1, 3
                call mesh_data_put_vertex(md, vb + vi, fv(vi), fn, &
                    mesh_data_face_uv(fv(vi), ext, ax, sg))
            end do
            t = t + 1
            call mesh_data_put_tri(md, t, vb + 1, vb + 2, vb + 3, fn, &
                                   .false., [255, 255, 255])
        end do
        vb = 12
        fn = compute_triangle_normal(p(4), p(2), p(3))
        do f = 1, 4
            call mesh_data_put_vertex(md, vb + f, p(f), fn, &
                mesh_data_face_uv(p(f), ext, 2, -1))
        end do
        t = t + 1
        call mesh_data_put_tri(md, t, vb + 4, vb + 2, vb + 3, fn, &
                               .false., [255, 255, 255])
        t = t + 1
        call mesh_data_put_tri(md, t, vb + 4, vb + 1, vb + 2, &
            compute_triangle_normal(p(4), p(1), p(2)), .false., &
            [255, 255, 255])
        call mesh_data_finalize(md)
    end subroutine build_pyramid_data

    subroutine create_pyramid(m, base, height)
        type(Mesh), intent(inout) :: m
        real(dp), intent(in) :: base, height
        type(mesh_data) :: md
        call build_pyramid_data(md, base, height)
        call mesh_data_to_triangles(md, m)
        call mesh_data_free(md)
    end subroutine create_pyramid

    ! Torus around Y, indexed grid: (seg+1) x (tube_segments+1)
    ! verts -- the +1 row/column are the UV-seam duplicates in both
    ! directions (same position/normal as the wrapped vertex).
    !   n_verts = (seg+1)*(tseg+1), n_tris = 2*seg*tseg.
    ! UV: u around the main ring, v around the tube.  Vertex normals
    ! analytic: normalize(position - tube centre).
    subroutine build_torus_data(md, radius, tube, segments, tube_segments)
        type(mesh_data), intent(out) :: md
        real(dp), intent(in) :: radius, tube
        integer, intent(in) :: segments, tube_segments
        integer :: seg, tseg, i, j, t, rb, rb2
        type(vec3) :: a, b, c, d, centroid

        seg = max(3, segments)
        tseg = max(3, tube_segments)
        call mesh_data_alloc(md, (seg + 1) * (tseg + 1), seg * tseg * 2)
        do i = 1, seg + 1
            rb = (i - 1) * (tseg + 1)
            do j = 1, tseg + 1
                a = torus_point(radius, tube, seg, tseg, &
                                mod(i - 1, seg) + 1, mod(j - 1, tseg) + 1)
                call mesh_data_put_vertex(md, rb + j, a, &
                    torus_normal(radius, a), &
                    [real(i - 1, dp) / real(seg, dp), &
                     real(j - 1, dp) / real(tseg, dp)])
            end do
        end do
        t = 0
        do i = 1, seg
            rb = (i - 1) * (tseg + 1)
            rb2 = i * (tseg + 1)
            do j = 1, tseg
                a = torus_point(radius, tube, seg, tseg, i, j)
                b = torus_point(radius, tube, seg, tseg, &
                                mod(i, seg) + 1, j)
                c = torus_point(radius, tube, seg, tseg, &
                                mod(i, seg) + 1, mod(j, tseg) + 1)
                d = torus_point(radius, tube, seg, tseg, i, &
                                mod(j, tseg) + 1)
                t = t + 1
                centroid = vec3_add(vec3_add(a, d), c)
                call mesh_data_put_tri(md, t, rb + j, rb + j + 1, &
                    rb2 + j + 1, &
                    torus_normal(radius, vec3_scale(centroid, &
                                                    1.0_dp / 3.0_dp)), &
                    .true., [255, 255, 255])
                t = t + 1
                centroid = vec3_add(vec3_add(a, c), b)
                call mesh_data_put_tri(md, t, rb + j, rb2 + j + 1, &
                    rb2 + j, &
                    torus_normal(radius, vec3_scale(centroid, &
                                                    1.0_dp / 3.0_dp)), &
                    .true., [255, 255, 255])
            end do
        end do
        call mesh_data_finalize(md)
    end subroutine build_torus_data

    subroutine create_torus(m, radius, tube, segments, tube_segments)
        type(Mesh), intent(inout) :: m
        real(dp), intent(in) :: radius, tube
        integer, intent(in) :: segments, tube_segments
        type(mesh_data) :: md
        call build_torus_data(md, radius, tube, segments, tube_segments)
        call mesh_data_to_triangles(md, m)
        call mesh_data_free(md)
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
                block
                    real(dp) :: swap_uv(2)
                    swap_uv = t%uv(:, 2); t%uv(:, 2) = t%uv(:, 3); &
                    t%uv(:, 3) = swap_uv
                end block
            end if
            t%normal = compute_triangle_normal(t%v(1), t%v(2), t%v(3))
            if (t%smooth) then
                do k = 1, 3
                    t%vn(k) = vec3_normalize(mat4_transform_vec3( &
                        model, src%triangles(i)%vn(k), .false.))
                end do
                if (flip) then
                    swap_v = t%vn(2); t%vn(2) = t%vn(3); t%vn(3) = swap_v
                end if
            else
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
