module renderer_3d
    use math_3d
    use mesh_3d
    use camera_3d
    use material_3d
    use material_pbr_3d, only: MaterialPBR
    use texture_3d, only: TextureImage, texture_sample, prim_uv
    use lighting_3d, only: LightSet, shade_rgb
    use shadow_3d, only: ShadowMap, shadow_factor, shadow_factor_pcf
    use shader_3d, only: ShaderProg, shader_eval
    implicit none
    private
    public :: FrameBuffer, framebuffer_init, framebuffer_clear, &
              framebuffer_render_mesh, framebuffer_render_mesh_mat, &
              framebuffer_render_mesh_env, &
              framebuffer_render_mesh_shader, &
              framebuffer_save_ppm, &
              ClipPoly, clip_triangle_frustum, CLIP_MAX_VERTS, &
              CLIP_ATTR_COUNT

    ! Homogeneous clip-space clipping (HK-R, defect D2).
    ! A triangle clipped against the 6 frustum planes gains at most
    ! one vertex per plane, so 3 + 6 = 9 vertices bound the result.
    ! CLIP_ATTR_COUNT generic per-vertex attributes are interpolated
    ! alongside the clip position: the env path uses them for
    ! (world_x, world_y, world_z, u, v, normal_x, normal_y,
    ! normal_z) -- attrs 6-8 carry the world-space vertex normal for
    ! smooth (Gouraud/Phong-interpolated) shading (P1); other paths
    ! leave them zero.
    integer, parameter :: CLIP_MAX_VERTS = 9
    integer, parameter :: CLIP_ATTR_COUNT = 8

    type :: ClipPoly
        integer :: n = 0
        real(dp) :: clip(4, CLIP_MAX_VERTS) = 0.0_dp
        real(dp) :: attr(CLIP_ATTR_COUNT, CLIP_MAX_VERTS) = 0.0_dp
    end type ClipPoly

    type :: FrameBuffer
        integer :: width
        integer :: height
        integer, allocatable :: pixels(:, :, :) ! (3, width, height) RGB
        real(dp), allocatable :: z_buffer(:, :)  ! (width, height)
    end type FrameBuffer

contains

    ! Signed distance-like plane function for frustum plane p:
    ! inside iff result >= 0.  Planes: w+x, w-x, w+y, w-y, w+z, w-z.
    pure function clip_plane_dist(p, c) result(d)
        integer, intent(in) :: p
        real(dp), intent(in) :: c(4)
        real(dp) :: d
        select case (p)
        case (1); d = c(4) + c(1)
        case (2); d = c(4) - c(1)
        case (3); d = c(4) + c(2)
        case (4); d = c(4) - c(2)
        case (5); d = c(4) + c(3)
        case default; d = c(4) - c(3)
        end select
    end function clip_plane_dist

    pure function clip_all_inside(clip_v) result(inside)
        real(dp), intent(in) :: clip_v(4, 3)
        logical :: inside
        integer :: p, k
        inside = .true.
        do p = 1, 6
            do k = 1, 3
                if (clip_plane_dist(p, clip_v(:, k)) < 0.0_dp) then
                    inside = .false.
                    return
                end if
            end do
        end do
    end function clip_all_inside

    ! Homogeneous transform WITHOUT the perspective divide.  The
    ! numerator arithmetic mirrors mat4_transform_vec3 term for term.
    pure function mat4_clip(m, v) result(c)
        type(mat4), intent(in) :: m
        type(vec3), intent(in) :: v
        real(dp) :: c(4)
        c(1) = m%m(1, 1) * v%x + m%m(1, 2) * v%y + m%m(1, 3) * v%z + m%m(1, 4)
        c(2) = m%m(2, 1) * v%x + m%m(2, 2) * v%y + m%m(2, 3) * v%z + m%m(2, 4)
        c(3) = m%m(3, 1) * v%x + m%m(3, 2) * v%y + m%m(3, 3) * v%z + m%m(3, 4)
        c(4) = m%m(4, 1) * v%x + m%m(4, 2) * v%y + m%m(4, 3) * v%z + m%m(4, 4)
    end function mat4_clip

    ! Sutherland-Hodgman clipping of one triangle against the 6
    ! homogeneous frustum planes, before any perspective divide.
    ! clip_in is (4,3) homogeneous positions; attr_in is
    ! (CLIP_ATTR_COUNT,3) per-vertex attributes, linearly interpolated
    ! at every intersection exactly like the clip position.
    pure subroutine clip_triangle_frustum(clip_in, attr_in, poly)
        real(dp), intent(in) :: clip_in(4, 3)
        real(dp), intent(in) :: attr_in(CLIP_ATTR_COUNT, 3)
        type(ClipPoly), intent(out) :: poly
        real(dp) :: cur_c(4, CLIP_MAX_VERTS), nxt_c(4, CLIP_MAX_VERTS)
        real(dp) :: cur_a(CLIP_ATTR_COUNT, CLIP_MAX_VERTS)
        real(dp) :: nxt_a(CLIP_ATTR_COUNT, CLIP_MAX_VERTS)
        real(dp) :: da, db, t
        integer :: p, i, j, cur_n, nxt_n
        logical :: a_in, b_in

        cur_c(:, 1:3) = clip_in
        cur_a(:, 1:3) = attr_in
        cur_n = 3
        do p = 1, 6
            if (cur_n == 0) exit
            nxt_n = 0
            do i = 1, cur_n
                j = mod(i, cur_n) + 1
                da = clip_plane_dist(p, cur_c(:, i))
                db = clip_plane_dist(p, cur_c(:, j))
                a_in = da >= 0.0_dp
                b_in = db >= 0.0_dp
                if (a_in .and. b_in) then
                    nxt_n = nxt_n + 1
                    nxt_c(:, nxt_n) = cur_c(:, j)
                    nxt_a(:, nxt_n) = cur_a(:, j)
                else if (a_in .and. .not. b_in) then
                    t = da / (da - db)
                    nxt_n = nxt_n + 1
                    nxt_c(:, nxt_n) = cur_c(:, i) + t * (cur_c(:, j) - cur_c(:, i))
                    nxt_a(:, nxt_n) = cur_a(:, i) + t * (cur_a(:, j) - cur_a(:, i))
                else if (.not. a_in .and. b_in) then
                    t = da / (da - db)
                    nxt_n = nxt_n + 1
                    nxt_c(:, nxt_n) = cur_c(:, i) + t * (cur_c(:, j) - cur_c(:, i))
                    nxt_a(:, nxt_n) = cur_a(:, i) + t * (cur_a(:, j) - cur_a(:, i))
                    nxt_n = nxt_n + 1
                    nxt_c(:, nxt_n) = cur_c(:, j)
                    nxt_a(:, nxt_n) = cur_a(:, j)
                end if
            end do
            cur_n = nxt_n
            if (cur_n > 0) then
                cur_c(:, 1:cur_n) = nxt_c(:, 1:cur_n)
                cur_a(:, 1:cur_n) = nxt_a(:, 1:cur_n)
            end if
        end do
        poly%n = cur_n
        poly%clip = 0.0_dp
        poly%attr = 0.0_dp
        if (cur_n > 0) then
            poly%clip(:, 1:cur_n) = cur_c(:, 1:cur_n)
            poly%attr(:, 1:cur_n) = cur_a(:, 1:cur_n)
        end if
    end subroutine clip_triangle_frustum

    subroutine framebuffer_init(fb, width, height)
        type(FrameBuffer), intent(out) :: fb
        integer, intent(in) :: width, height

        fb%width = width
        fb%height = height
        allocate(fb%pixels(3, width, height))
        allocate(fb%z_buffer(width, height))
        call framebuffer_clear(fb, 25, 25, 35)
    end subroutine framebuffer_init

    subroutine framebuffer_clear(fb, r, g, b)
        type(FrameBuffer), intent(inout) :: fb
        integer, intent(in) :: r, g, b

        fb%pixels(1, :, :) = r
        fb%pixels(2, :, :) = g
        fb%pixels(3, :, :) = b
        fb%z_buffer(:, :) = 1.0e10_dp
    end subroutine framebuffer_clear

    ! Legacy entry point, preserved exactly: a wrapper that renders with
    ! the default material (lambert, per-triangle colour), whose ambient
    ! level defaults to 0.25, i.e. intensity = 0.25 + 0.75 * diffuse.
    subroutine framebuffer_render_mesh(fb, target_mesh, model_matrix, cam, light_dir)
        type(FrameBuffer), intent(inout) :: fb
        type(Mesh), intent(in) :: target_mesh
        type(mat4), intent(in) :: model_matrix
        type(Camera), intent(in) :: cam
        type(vec3), intent(in) :: light_dir

        type(Material) :: mat

        mat = material_default()
        call framebuffer_render_mesh_mat(fb, target_mesh, model_matrix, cam, light_dir, mat)
    end subroutine framebuffer_render_mesh

    ! Material-aware rendering, directional light only.
    !   base colour = tri%color/255 if mat%use_tri_color, else mat%color
    !   mat%mode: 0 = lambert, 1 = basic (unlit), 2 = phong (lambert+specular)
    !   lambert/phong intensity = ambient + (1 - ambient) * diffuse
    ! Backface culling and the z-buffer behave as in the legacy path.
    subroutine framebuffer_render_mesh_mat(fb, target_mesh, model_matrix, cam, light_dir, mat, ambient_level)
        type(FrameBuffer), intent(inout) :: fb
        type(Mesh), intent(in) :: target_mesh
        type(mat4), intent(in) :: model_matrix
        type(Camera), intent(in) :: cam
        type(vec3), intent(in) :: light_dir
        type(Material), intent(in) :: mat
        real(dp), intent(in), optional :: ambient_level

        type(mat4) :: mvp, model_view
        type(Triangle) :: tri
        type(vec3) :: world_v(3), proj_v(3), normal_world
        type(vec3) :: norm_light, centroid, view_dir, refl_dir
        real(dp) :: ambient, intensity, diffuse, spec
        real(dp) :: base_color(3), rgb_real(3)
        integer :: rgb(3)
        ! P1 smooth shading: per-vertex world normals + per-vertex
        ! real RGB (channel, vertex), used only when tri%smooth.
        type(vec3) :: vnormal_world(3), v_view_dir, v_refl_dir
        real(dp) :: v_intensity, v_diffuse, v_spec, rgb_v(3, 3)
        integer :: i, k, sx(3), sy(3)
        real(dp) :: z(3)
        real(dp) :: clip_v(4, 3), attr_zero(CLIP_ATTR_COUNT, 3)
        real(dp) :: ndc(3)
        type(ClipPoly) :: poly
        integer :: piece, idx(3), q

        if (present(ambient_level)) then
            ambient = ambient_level
        else
            ambient = 0.25_dp
        end if

        norm_light = vec3_normalize(light_dir)
        model_view = mat4_mult(cam%view_matrix, model_matrix)
        mvp = mat4_mult(cam%proj_matrix, model_view)

        do i = 1, target_mesh%num_triangles
            tri = target_mesh%triangles(i)
            rgb_v = 0.0_dp  ! P1: filled below only when tri%smooth

            ! Transform vertices to world coordinates for lighting
            world_v(1) = mat4_transform_vec3(model_matrix, tri%v(1), .true.)
            world_v(2) = mat4_transform_vec3(model_matrix, tri%v(2), .true.)
            world_v(3) = mat4_transform_vec3(model_matrix, tri%v(3), .true.)

            normal_world = compute_triangle_normal(world_v(1), world_v(2), world_v(3))

            ! Directional light calculation (Lambertian + ambient)
            diffuse = max(0.0_dp, vec3_dot(normal_world, vec3_scale(norm_light, -1.0_dp)))

            select case (mat%mode)
            case (1) ! basic: unlit, colour as-is
                intensity = 1.0_dp
                spec = 0.0_dp
            case (2) ! phong: lambert plus white specular highlight
                intensity = ambient + (1.0_dp - ambient) * diffuse
                centroid = vec3_scale(vec3_add(vec3_add(world_v(1), world_v(2)), world_v(3)), &
                                      1.0_dp / 3.0_dp)
                view_dir = vec3_normalize(vec3_sub(cam%position, centroid))
                refl_dir = vec3_reflect(vec3_negate(norm_light), normal_world)
                spec = mat%specular * max(0.0_dp, vec3_dot(refl_dir, view_dir)) ** mat%shininess
            case default ! 0 = lambert (unknown modes fall back to lambert)
                intensity = ambient + (1.0_dp - ambient) * diffuse
                spec = 0.0_dp
            end select

            ! Final RGB: per-triangle colour keeps the legacy integer
            ! scaling exactly; material colour is real 0..1 scaled by 255.
            if (mat%use_tri_color) then
                do k = 1, 3
                    rgb_real(k) = real(tri%color(k), dp) * intensity + spec * 255.0_dp
                end do
            else
                base_color = mat%color
                do k = 1, 3
                    rgb_real(k) = base_color(k) * 255.0_dp * intensity + spec * 255.0_dp
                end do
            end if
            rgb = min(255, max(0, int(rgb_real)))

            ! P1: for smooth triangles, evaluate the SAME lighting
            ! formula at each vertex, using the world-space vertex
            ! normal (direction transform of tri%vn(k) by the model
            ! matrix -- mat4_transform_vec3 with is_point=.false.
            ! applies the rotation without translation -- then
            ! renormalised).  For phong the view direction is taken
            ! from the vertex world position itself (the flat path
            ! uses the triangle centroid); every other term mirrors
            ! the per-triangle code above exactly.  Flat triangles
            ! never touch rgb_v and keep the path above byte-for-byte.
            if (tri%smooth) then
                do k = 1, 3
                    vnormal_world(k) = vec3_normalize( &
                        mat4_transform_vec3(model_matrix, tri%vn(k), &
                                            .false.))
                    v_diffuse = max(0.0_dp, vec3_dot(vnormal_world(k), &
                        vec3_scale(norm_light, -1.0_dp)))
                    select case (mat%mode)
                    case (1) ! basic: unlit, colour as-is
                        v_intensity = 1.0_dp
                        v_spec = 0.0_dp
                    case (2) ! phong: lambert plus white specular
                        v_intensity = ambient + &
                            (1.0_dp - ambient) * v_diffuse
                        v_view_dir = vec3_normalize( &
                            vec3_sub(cam%position, world_v(k)))
                        v_refl_dir = vec3_reflect( &
                            vec3_negate(norm_light), vnormal_world(k))
                        v_spec = mat%specular * &
                            max(0.0_dp, vec3_dot(v_refl_dir, &
                                v_view_dir)) ** mat%shininess
                    case default ! 0 = lambert
                        v_intensity = ambient + &
                            (1.0_dp - ambient) * v_diffuse
                        v_spec = 0.0_dp
                    end select
                    if (mat%use_tri_color) then
                        do q = 1, 3
                            rgb_v(q, k) = real(tri%color(q), dp) * &
                                v_intensity + v_spec * 255.0_dp
                        end do
                    else
                        do q = 1, 3
                            rgb_v(q, k) = base_color(q) * 255.0_dp * &
                                v_intensity + v_spec * 255.0_dp
                        end do
                    end if
                end do
            end if

            ! Homogeneous clip positions (no divide yet).
            clip_v(:, 1) = mat4_clip(mvp, tri%v(1))
            clip_v(:, 2) = mat4_clip(mvp, tri%v(2))
            clip_v(:, 3) = mat4_clip(mvp, tri%v(3))

            if (clip_all_inside(clip_v)) then
                ! Fast path: EXACTLY the original code / arithmetic.
                ! Transform to NDC clip space
                proj_v(1) = mat4_transform_vec3(mvp, tri%v(1), .true.)
                proj_v(2) = mat4_transform_vec3(mvp, tri%v(2), .true.)
                proj_v(3) = mat4_transform_vec3(mvp, tri%v(3), .true.)

                ! Backface culling check in screen coordinates
                sx(1) = int((proj_v(1)%x + 1.0_dp) * 0.5_dp * fb%width)
                sy(1) = int((1.0_dp - (proj_v(1)%y + 1.0_dp) * 0.5_dp) * fb%height)
                z(1)  = proj_v(1)%z

                sx(2) = int((proj_v(2)%x + 1.0_dp) * 0.5_dp * fb%width)
                sy(2) = int((1.0_dp - (proj_v(2)%y + 1.0_dp) * 0.5_dp) * fb%height)
                z(2)  = proj_v(2)%z

                sx(3) = int((proj_v(3)%x + 1.0_dp) * 0.5_dp * fb%width)
                sy(3) = int((1.0_dp - (proj_v(3)%y + 1.0_dp) * 0.5_dp) * fb%height)
                z(3)  = proj_v(3)%z

                ! Simple 2D cross product for winding / culling
                if ((sx(2) - sx(1)) * (sy(3) - sy(1)) - (sy(2) - sy(1)) * (sx(3) - sx(1)) <= 0) cycle

                ! Rasterize triangle
                if (tri%smooth) then
                    call draw_triangle_gouraud(fb, sx, sy, z, rgb_v)
                else
                    call draw_triangle_rgb(fb, sx, sy, z, rgb)
                end if
            else
                ! Clipped path: clip in homogeneous space, divide only
                ! the surviving vertices, fan-triangulate.
                ! P1 note: smooth triangles on this clipped path fall
                ! back to FLAT shading of the clipped pieces (the
                ! per-triangle rgb computed above from the face
                ! normal).  Clipped smooth triangles are an edge case
                ! (only triangles straddling the frustum), and the
                ! clip system is deliberately NOT restructured to
                ! carry per-vertex colours for them.
                attr_zero = 0.0_dp
                call clip_triangle_frustum(clip_v, attr_zero, poly)
                if (poly%n < 3) cycle
                do piece = 2, poly%n - 1
                    idx = [1, piece, piece + 1]
                    do q = 1, 3
                        if (abs(poly%clip(4, idx(q))) <= 1.0e-12_dp) then
                            ndc = 0.0_dp
                            sx(q) = -1000000
                            sy(q) = -1000000
                            z(q) = 0.0_dp
                        else
                            ndc = poly%clip(1:3, idx(q)) / poly%clip(4, idx(q))
                            sx(q) = int((ndc(1) + 1.0_dp) * 0.5_dp * fb%width)
                            sy(q) = int((1.0_dp - (ndc(2) + 1.0_dp) * 0.5_dp) * fb%height)
                            z(q) = ndc(3)
                        end if
                    end do
                    if (any(abs(poly%clip(4, idx)) <= 1.0e-12_dp)) cycle
                    if ((sx(2) - sx(1)) * (sy(3) - sy(1)) - &
                        (sy(2) - sy(1)) * (sx(3) - sx(1)) <= 0) cycle
                    call draw_triangle_rgb(fb, sx, sy, z, rgb)
                end do
            end if
        end do
    end subroutine framebuffer_render_mesh_mat

    ! Shared rasteriser: callers pass the final RGB ints for the triangle.
    subroutine draw_triangle_rgb(fb, x, y, z, rgb)
        type(FrameBuffer), intent(inout) :: fb
        integer, intent(in) :: x(3), y(3)
        real(dp), intent(in) :: z(3)
        integer, intent(in) :: rgb(3)

        integer :: min_x, max_x, min_y, max_y, px, py
        real(dp) :: w0, w1, w2, denom, depth
        integer :: r, g, b

        r = rgb(1)
        g = rgb(2)
        b = rgb(3)

        min_x = max(1, min(x(1), min(x(2), x(3))))
        max_x = min(fb%width, max(x(1), max(x(2), x(3))))
        min_y = max(1, min(y(1), min(y(2), y(3))))
        max_y = min(fb%height, max(y(1), max(y(2), y(3))))

        denom = real((y(2) - y(3)) * (x(1) - x(3)) + (x(3) - x(2)) * (y(1) - y(3)), dp)
        if (abs(denom) < 1.0e-6_dp) return

        do py = min_y, max_y
            do px = min_x, max_x
                w0 = real((y(2) - y(3)) * (px - x(3)) + (x(3) - x(2)) * (py - y(3)), dp) / denom
                w1 = real((y(3) - y(1)) * (px - x(3)) + (x(1) - x(3)) * (py - y(3)), dp) / denom
                w2 = 1.0_dp - w0 - w1

                if (w0 >= 0.0_dp .and. w1 >= 0.0_dp .and. w2 >= 0.0_dp) then
                    depth = w0 * z(1) + w1 * z(2) + w2 * z(3)
                    if (depth >= -1.0_dp .and. depth <= 1.0_dp .and. depth < fb%z_buffer(px, py)) then
                        fb%z_buffer(px, py) = depth
                        fb%pixels(1, px, py) = r
                        fb%pixels(2, px, py) = g
                        fb%pixels(3, px, py) = b
                    end if
                end if
            end do
        end do
    end subroutine draw_triangle_rgb

    ! P1 Gouraud rasteriser: identical barycentric rasterisation and
    ! z interpolation to draw_triangle_rgb (same bounding box, denom,
    ! weight formulas and depth test, in the same order); the ONLY
    ! difference is that the per-vertex real RGB rgb_v (channel,
    ! vertex) is barycentrically interpolated per pixel and then
    ! converted/clamped exactly as the flat path converts rgb_real
    ! (min(255, max(0, int(...)))).
    subroutine draw_triangle_gouraud(fb, x, y, z, rgb_v)
        type(FrameBuffer), intent(inout) :: fb
        integer, intent(in) :: x(3), y(3)
        real(dp), intent(in) :: z(3)
        real(dp), intent(in) :: rgb_v(3, 3)

        integer :: min_x, max_x, min_y, max_y, px, py
        real(dp) :: w0, w1, w2, denom, depth
        real(dp) :: r_real, g_real, b_real

        min_x = max(1, min(x(1), min(x(2), x(3))))
        max_x = min(fb%width, max(x(1), max(x(2), x(3))))
        min_y = max(1, min(y(1), min(y(2), y(3))))
        max_y = min(fb%height, max(y(1), max(y(2), y(3))))

        denom = real((y(2) - y(3)) * (x(1) - x(3)) + (x(3) - x(2)) * (y(1) - y(3)), dp)
        if (abs(denom) < 1.0e-6_dp) return

        do py = min_y, max_y
            do px = min_x, max_x
                w0 = real((y(2) - y(3)) * (px - x(3)) + (x(3) - x(2)) * (py - y(3)), dp) / denom
                w1 = real((y(3) - y(1)) * (px - x(3)) + (x(1) - x(3)) * (py - y(3)), dp) / denom
                w2 = 1.0_dp - w0 - w1

                if (w0 >= 0.0_dp .and. w1 >= 0.0_dp .and. w2 >= 0.0_dp) then
                    depth = w0 * z(1) + w1 * z(2) + w2 * z(3)
                    if (depth >= -1.0_dp .and. depth <= 1.0_dp .and. depth < fb%z_buffer(px, py)) then
                        r_real = w0 * rgb_v(1, 1) + w1 * rgb_v(1, 2) + w2 * rgb_v(1, 3)
                        g_real = w0 * rgb_v(2, 1) + w1 * rgb_v(2, 2) + w2 * rgb_v(2, 3)
                        b_real = w0 * rgb_v(3, 1) + w1 * rgb_v(3, 2) + w2 * rgb_v(3, 3)
                        fb%z_buffer(px, py) = depth
                        fb%pixels(1, px, py) = min(255, max(0, int(r_real)))
                        fb%pixels(2, px, py) = min(255, max(0, int(g_real)))
                        fb%pixels(3, px, py) = min(255, max(0, int(b_real)))
                    end if
                end if
            end do
        end do
    end subroutine draw_triangle_gouraud

    ! Wave A environment rendering (coordinator integration, Wave A).
    ! Per-pixel shading through lighting_3d: multi-light (directional /
    ! point / spot), PBR materials, per-pixel texture sampling with
    ! barycentric UV interpolation (texture_3d prim_uv contract) and
    ! per-pixel shadow-map lookup. Only called by main's scene path when
    ! the scene actually uses Wave A features; the legacy entry points
    ! above are untouched, so default scenes stay byte-identical.
    subroutine framebuffer_render_mesh_env(fb, target_mesh, model_matrix, &
                                           cam, lights, pbr, tex, prim, &
                                           extents, smap, shadow_mode)
        type(FrameBuffer), intent(inout) :: fb
        type(Mesh), intent(in) :: target_mesh
        type(mat4), intent(in) :: model_matrix
        type(Camera), intent(in) :: cam
        type(LightSet), intent(in) :: lights
        type(MaterialPBR), intent(in) :: pbr
        type(TextureImage), intent(in) :: tex
        character(len=*), intent(in) :: prim
        real(dp), intent(in) :: extents(3)
        type(ShadowMap), intent(in) :: smap
        integer, intent(in) :: shadow_mode  ! 0 off, 1 hard, 2 soft (PCF)

        type(mat4) :: mvp, model_view
        type(Triangle) :: tri
        type(vec3) :: world_v(3), proj_v(3), normal_world
        integer :: i, sx(3), sy(3)
        real(dp) :: z(3), uv(2, 3)
        real(dp) :: clip_v(4, 3), attr_in(CLIP_ATTR_COUNT, 3)
        real(dp) :: ndc(3), uv_piece(2, 3)
        type(vec3) :: world_piece(3)
        ! P1: world-space per-vertex normals (attrs 6-8 when clipped).
        ! Smooth tris use the direction-transformed tri%vn(k),
        ! renormalised; flat tris get normal_world at every vertex so
        ! their shading is identical to the pre-P1 path.
        type(vec3) :: vnormal_world(3), normal_piece(3)
        type(ClipPoly) :: poly
        integer :: piece, idx(3), q

        model_view = mat4_mult(cam%view_matrix, model_matrix)
        mvp = mat4_mult(cam%proj_matrix, model_view)

        do i = 1, target_mesh%num_triangles
            tri = target_mesh%triangles(i)

            world_v(1) = mat4_transform_vec3(model_matrix, tri%v(1), .true.)
            world_v(2) = mat4_transform_vec3(model_matrix, tri%v(2), .true.)
            world_v(3) = mat4_transform_vec3(model_matrix, tri%v(3), .true.)
            normal_world = compute_triangle_normal(world_v(1), world_v(2), &
                                                   world_v(3))

            ! P1 per-vertex world normals (see declaration note).
            if (tri%smooth) then
                do q = 1, 3
                    vnormal_world(q) = vec3_normalize( &
                        mat4_transform_vec3(model_matrix, tri%vn(q), &
                                            .false.))
                end do
            else
                vnormal_world(1) = normal_world
                vnormal_world(2) = normal_world
                vnormal_world(3) = normal_world
            end if

            clip_v(:, 1) = mat4_clip(mvp, tri%v(1))
            clip_v(:, 2) = mat4_clip(mvp, tri%v(2))
            clip_v(:, 3) = mat4_clip(mvp, tri%v(3))

            if (clip_all_inside(clip_v)) then
                ! Fast path: EXACTLY the original code / arithmetic.
                proj_v(1) = mat4_transform_vec3(mvp, tri%v(1), .true.)
                proj_v(2) = mat4_transform_vec3(mvp, tri%v(2), .true.)
                proj_v(3) = mat4_transform_vec3(mvp, tri%v(3), .true.)

                sx(1) = int((proj_v(1)%x + 1.0_dp) * 0.5_dp * fb%width)
                sy(1) = int((1.0_dp - (proj_v(1)%y + 1.0_dp) * 0.5_dp) * fb%height)
                z(1)  = proj_v(1)%z
                sx(2) = int((proj_v(2)%x + 1.0_dp) * 0.5_dp * fb%width)
                sy(2) = int((1.0_dp - (proj_v(2)%y + 1.0_dp) * 0.5_dp) * fb%height)
                z(2)  = proj_v(2)%z
                sx(3) = int((proj_v(3)%x + 1.0_dp) * 0.5_dp * fb%width)
                sy(3) = int((1.0_dp - (proj_v(3)%y + 1.0_dp) * 0.5_dp) * fb%height)
                z(3)  = proj_v(3)%z

                if ((sx(2) - sx(1)) * (sy(3) - sy(1)) - &
                    (sy(2) - sy(1)) * (sx(3) - sx(1)) <= 0) cycle

                uv(:, 1) = prim_uv(prim, tri%v(1), extents)
                uv(:, 2) = prim_uv(prim, tri%v(2), extents)
                uv(:, 3) = prim_uv(prim, tri%v(3), extents)

                call draw_triangle_env(fb, sx, sy, z, world_v, uv, tri, &
                                       normal_world, vnormal_world, &
                                       cam, lights, pbr, tex, &
                                       smap, shadow_mode)
            else
                uv(:, 1) = prim_uv(prim, tri%v(1), extents)
                uv(:, 2) = prim_uv(prim, tri%v(2), extents)
                uv(:, 3) = prim_uv(prim, tri%v(3), extents)
                do q = 1, 3
                    attr_in(1, q) = world_v(q)%x
                    attr_in(2, q) = world_v(q)%y
                    attr_in(3, q) = world_v(q)%z
                    attr_in(4, q) = uv(1, q)
                    attr_in(5, q) = uv(2, q)
                    attr_in(6, q) = vnormal_world(q)%x
                    attr_in(7, q) = vnormal_world(q)%y
                    attr_in(8, q) = vnormal_world(q)%z
                end do
                call clip_triangle_frustum(clip_v, attr_in, poly)
                if (poly%n < 3) cycle
                do piece = 2, poly%n - 1
                    idx = [1, piece, piece + 1]
                    if (any(abs(poly%clip(4, idx)) <= 1.0e-12_dp)) cycle
                    do q = 1, 3
                        ndc = poly%clip(1:3, idx(q)) / poly%clip(4, idx(q))
                        sx(q) = int((ndc(1) + 1.0_dp) * 0.5_dp * fb%width)
                        sy(q) = int((1.0_dp - (ndc(2) + 1.0_dp) * 0.5_dp) * fb%height)
                        z(q) = ndc(3)
                        world_piece(q) = vec3_create(poly%attr(1, idx(q)), &
                                                     poly%attr(2, idx(q)), &
                                                     poly%attr(3, idx(q)))
                        uv_piece(1, q) = poly%attr(4, idx(q))
                        uv_piece(2, q) = poly%attr(5, idx(q))
                        normal_piece(q) = vec3_create( &
                            poly%attr(6, idx(q)), &
                            poly%attr(7, idx(q)), &
                            poly%attr(8, idx(q)))
                    end do
                    if ((sx(2) - sx(1)) * (sy(3) - sy(1)) - &
                        (sy(2) - sy(1)) * (sx(3) - sx(1)) <= 0) cycle
                    call draw_triangle_env(fb, sx, sy, z, world_piece, &
                                           uv_piece, tri, normal_world, &
                                           normal_piece, &
                                           cam, lights, pbr, tex, &
                                           smap, shadow_mode)
                end do
            end if
        end do
    end subroutine framebuffer_render_mesh_env

    subroutine draw_triangle_env(fb, x, y, z, world_v, uv, tri, &
                                 normal_world, vnormal_world, &
                                 cam, lights, pbr, tex, &
                                 smap, shadow_mode)
        type(FrameBuffer), intent(inout) :: fb
        integer, intent(in) :: x(3), y(3)
        real(dp), intent(in) :: z(3), uv(2, 3)
        type(vec3), intent(in) :: world_v(3), normal_world
        type(vec3), intent(in) :: vnormal_world(3)
        type(Triangle), intent(in) :: tri
        type(Camera), intent(in) :: cam
        type(LightSet), intent(in) :: lights
        type(MaterialPBR), intent(in) :: pbr
        type(TextureImage), intent(in) :: tex
        type(ShadowMap), intent(in) :: smap
        integer, intent(in) :: shadow_mode

        integer :: min_x, max_x, min_y, max_y, px, py
        real(dp) :: w0, w1, w2, denom, depth, sfac
        real(dp) :: u_interp, v_interp
        type(vec3) :: wp, n_interp, shade_normal
        integer :: base_rgb(3), rgb(3)

        min_x = max(1, min(x(1), min(x(2), x(3))))
        max_x = min(fb%width, max(x(1), max(x(2), x(3))))
        min_y = max(1, min(y(1), min(y(2), y(3))))
        max_y = min(fb%height, max(y(1), max(y(2), y(3))))

        denom = real((y(2) - y(3)) * (x(1) - x(3)) + &
                     (x(3) - x(2)) * (y(1) - y(3)), dp)
        if (abs(denom) < 1.0e-6_dp) return

        do py = min_y, max_y
            do px = min_x, max_x
                w0 = real((y(2) - y(3)) * (px - x(3)) + &
                          (x(3) - x(2)) * (py - y(3)), dp) / denom
                w1 = real((y(3) - y(1)) * (px - x(3)) + &
                          (x(1) - x(3)) * (py - y(3)), dp) / denom
                w2 = 1.0_dp - w0 - w1
                if (w0 < 0.0_dp .or. w1 < 0.0_dp .or. w2 < 0.0_dp) cycle

                depth = w0 * z(1) + w1 * z(2) + w2 * z(3)
                if (depth < -1.0_dp .or. depth > 1.0_dp) cycle
                if (depth >= fb%z_buffer(px, py)) cycle

                wp = vec3_create( &
                    w0 * world_v(1)%x + w1 * world_v(2)%x + &
                    w2 * world_v(3)%x, &
                    w0 * world_v(1)%y + w1 * world_v(2)%y + &
                    w2 * world_v(3)%y, &
                    w0 * world_v(1)%z + w1 * world_v(2)%z + &
                    w2 * world_v(3)%z)

                if (tex%loaded) then
                    u_interp = w0 * uv(1, 1) + w1 * uv(1, 2) + &
                               w2 * uv(1, 3)
                    v_interp = w0 * uv(2, 1) + w1 * uv(2, 2) + &
                               w2 * uv(2, 3)
                    base_rgb = texture_sample(tex, u_interp, v_interp)
                else if (pbr%use_tri_color) then
                    base_rgb = tri%color
                else
                    base_rgb = int(pbr%color * 255.0_dp)
                end if

                sfac = 1.0_dp
                if (shadow_mode == 1) then
                    sfac = shadow_factor(smap, wp, 0.002_dp)
                else if (shadow_mode >= 2) then
                    sfac = shadow_factor_pcf(smap, wp, 0.002_dp)
                end if

                ! P1: smooth triangles shade with the per-pixel
                ! barycentric-interpolated, renormalised vertex
                ! normal; flat triangles use normal_world exactly as
                ! before (identical results).
                if (tri%smooth) then
                    n_interp = vec3_create( &
                        w0 * vnormal_world(1)%x + &
                        w1 * vnormal_world(2)%x + &
                        w2 * vnormal_world(3)%x, &
                        w0 * vnormal_world(1)%y + &
                        w1 * vnormal_world(2)%y + &
                        w2 * vnormal_world(3)%y, &
                        w0 * vnormal_world(1)%z + &
                        w1 * vnormal_world(2)%z + &
                        w2 * vnormal_world(3)%z)
                    shade_normal = vec3_normalize(n_interp)
                else
                    shade_normal = normal_world
                end if

                rgb = shade_rgb(base_rgb, shade_normal, wp, &
                                cam%position, lights, pbr, sfac)

                fb%z_buffer(px, py) = depth
                fb%pixels(1, px, py) = rgb(1)
                fb%pixels(2, px, py) = rgb(2)
                fb%pixels(3, px, py) = rgb(3)
            end do
        end do
    end subroutine draw_triangle_env

    ! Wave E custom-shader rendering (C2).
    ! Mirrors framebuffer_render_mesh_mat's transform / backface
    ! culling / homogeneous clipping structure, but rasterizes
    ! per-pixel like draw_triangle_env: world position is
    ! barycentric-interpolated per pixel and handed to the user
    ! shader program (shader_3d) together with u = w1, v = w2
    ! (the second / third barycentric weights), the per-triangle
    ! diffuse ndl and the time t_sec.  Base colour follows _mat
    ! exactly: the triangle colour when mat%use_tri_color, else
    ! the material colour.  Per channel k the shader is evaluated
    ! with c = base channel k (0..1) and r/g/b = the full base
    ! colour (0..1); its result is clamped to 0..1 and rounded
    ! with nint to 0..255.  ambient_level is accepted for signature
    ! parity with framebuffer_render_mesh_mat: the shader program
    ! itself decides how to use ndl, so the renderer deliberately
    ! does NOT pre-scale by ambient / intensity -- that is what
    ! makes the identity shader `c` reproduce the unlit flat
    ! render exactly.  Default scenes never call this routine, so
    ! existing renders are unaffected.
    subroutine framebuffer_render_mesh_shader(fb, target_mesh, &
            model_matrix, cam, light_dir, mat, ambient_level, &
            prog, t_sec)
        type(FrameBuffer), intent(inout) :: fb
        type(Mesh), intent(in) :: target_mesh
        type(mat4), intent(in) :: model_matrix
        type(Camera), intent(in) :: cam
        type(vec3), intent(in) :: light_dir
        type(Material), intent(in) :: mat
        real(dp), intent(in) :: ambient_level
        type(ShaderProg), intent(in) :: prog
        real(dp), intent(in) :: t_sec

        type(mat4) :: mvp, model_view
        type(Triangle) :: tri
        type(vec3) :: world_v(3), proj_v(3), normal_world
        type(vec3) :: norm_light
        real(dp) :: diffuse
        real(dp) :: base01(3)
        integer :: i, k, sx(3), sy(3)
        real(dp) :: z(3)
        real(dp) :: clip_v(4, 3), attr_in(CLIP_ATTR_COUNT, 3)
        real(dp) :: ndc(3)
        type(vec3) :: world_piece(3)
        type(ClipPoly) :: poly
        integer :: piece, idx(3), q
        real(dp) :: ambient_parity

        ! Signature parity only (see header comment): referenced so
        ! the dummy is not unused, with no effect on any pixel.
        ambient_parity = ambient_level
        if (ambient_parity > huge(1.0_dp)) return

        norm_light = vec3_normalize(light_dir)
        model_view = mat4_mult(cam%view_matrix, model_matrix)
        mvp = mat4_mult(cam%proj_matrix, model_view)

        do i = 1, target_mesh%num_triangles
            tri = target_mesh%triangles(i)

            world_v(1) = mat4_transform_vec3(model_matrix, tri%v(1), .true.)
            world_v(2) = mat4_transform_vec3(model_matrix, tri%v(2), .true.)
            world_v(3) = mat4_transform_vec3(model_matrix, tri%v(3), .true.)

            normal_world = compute_triangle_normal(world_v(1), world_v(2), world_v(3))

            diffuse = max(0.0_dp, vec3_dot(normal_world, vec3_scale(norm_light, -1.0_dp)))

            if (mat%use_tri_color) then
                do k = 1, 3
                    base01(k) = real(tri%color(k), dp) / 255.0_dp
                end do
            else
                base01 = mat%color
            end if

            clip_v(:, 1) = mat4_clip(mvp, tri%v(1))
            clip_v(:, 2) = mat4_clip(mvp, tri%v(2))
            clip_v(:, 3) = mat4_clip(mvp, tri%v(3))

            if (clip_all_inside(clip_v)) then
                proj_v(1) = mat4_transform_vec3(mvp, tri%v(1), .true.)
                proj_v(2) = mat4_transform_vec3(mvp, tri%v(2), .true.)
                proj_v(3) = mat4_transform_vec3(mvp, tri%v(3), .true.)

                sx(1) = int((proj_v(1)%x + 1.0_dp) * 0.5_dp * fb%width)
                sy(1) = int((1.0_dp - (proj_v(1)%y + 1.0_dp) * 0.5_dp) * fb%height)
                z(1)  = proj_v(1)%z
                sx(2) = int((proj_v(2)%x + 1.0_dp) * 0.5_dp * fb%width)
                sy(2) = int((1.0_dp - (proj_v(2)%y + 1.0_dp) * 0.5_dp) * fb%height)
                z(2)  = proj_v(2)%z
                sx(3) = int((proj_v(3)%x + 1.0_dp) * 0.5_dp * fb%width)
                sy(3) = int((1.0_dp - (proj_v(3)%y + 1.0_dp) * 0.5_dp) * fb%height)
                z(3)  = proj_v(3)%z

                if ((sx(2) - sx(1)) * (sy(3) - sy(1)) - &
                    (sy(2) - sy(1)) * (sx(3) - sx(1)) <= 0) cycle

                call draw_triangle_shader(fb, sx, sy, z, world_v, &
                                          base01, diffuse, prog, t_sec)
            else
                do q = 1, 3
                    attr_in(1, q) = world_v(q)%x
                    attr_in(2, q) = world_v(q)%y
                    attr_in(3, q) = world_v(q)%z
                    attr_in(4, q) = 0.0_dp
                    attr_in(5, q) = 0.0_dp
                    ! P1: attrs 6-8 (vertex normals) grew with
                    ! CLIP_ATTR_COUNT; the shader path does not use
                    ! them -- keep them explicitly zero.
                    attr_in(6, q) = 0.0_dp
                    attr_in(7, q) = 0.0_dp
                    attr_in(8, q) = 0.0_dp
                end do
                call clip_triangle_frustum(clip_v, attr_in, poly)
                if (poly%n < 3) cycle
                do piece = 2, poly%n - 1
                    idx = [1, piece, piece + 1]
                    if (any(abs(poly%clip(4, idx)) <= 1.0e-12_dp)) cycle
                    do q = 1, 3
                        ndc = poly%clip(1:3, idx(q)) / poly%clip(4, idx(q))
                        sx(q) = int((ndc(1) + 1.0_dp) * 0.5_dp * fb%width)
                        sy(q) = int((1.0_dp - (ndc(2) + 1.0_dp) * 0.5_dp) * fb%height)
                        z(q) = ndc(3)
                        world_piece(q) = vec3_create(poly%attr(1, idx(q)), &
                                                     poly%attr(2, idx(q)), &
                                                     poly%attr(3, idx(q)))
                    end do
                    if ((sx(2) - sx(1)) * (sy(3) - sy(1)) - &
                        (sy(2) - sy(1)) * (sx(3) - sx(1)) <= 0) cycle
                    call draw_triangle_shader(fb, sx, sy, z, &
                                              world_piece, base01, &
                                              diffuse, prog, t_sec)
                end do
            end if
        end do
    end subroutine framebuffer_render_mesh_shader

    ! Per-pixel rasteriser for the custom-shader path: same
    ! barycentric / z-buffer discipline as draw_triangle_env.
    subroutine draw_triangle_shader(fb, x, y, z, world_v, base01, &
                                    ndl, prog, t_sec)
        type(FrameBuffer), intent(inout) :: fb
        integer, intent(in) :: x(3), y(3)
        real(dp), intent(in) :: z(3), base01(3), ndl, t_sec
        type(vec3), intent(in) :: world_v(3)
        type(ShaderProg), intent(in) :: prog

        integer :: min_x, max_x, min_y, max_y, px, py, k
        real(dp) :: w0, w1, w2, denom, depth
        real(dp) :: u_interp, v_interp, out_val
        type(vec3) :: wp
        integer :: rgb(3)

        min_x = max(1, min(x(1), min(x(2), x(3))))
        max_x = min(fb%width, max(x(1), max(x(2), x(3))))
        min_y = max(1, min(y(1), min(y(2), y(3))))
        max_y = min(fb%height, max(y(1), max(y(2), y(3))))

        denom = real((y(2) - y(3)) * (x(1) - x(3)) + &
                     (x(3) - x(2)) * (y(1) - y(3)), dp)
        if (abs(denom) < 1.0e-6_dp) return

        do py = min_y, max_y
            do px = min_x, max_x
                w0 = real((y(2) - y(3)) * (px - x(3)) + &
                          (x(3) - x(2)) * (py - y(3)), dp) / denom
                w1 = real((y(3) - y(1)) * (px - x(3)) + &
                          (x(1) - x(3)) * (py - y(3)), dp) / denom
                w2 = 1.0_dp - w0 - w1
                if (w0 < 0.0_dp .or. w1 < 0.0_dp .or. w2 < 0.0_dp) cycle

                depth = w0 * z(1) + w1 * z(2) + w2 * z(3)
                if (depth < -1.0_dp .or. depth > 1.0_dp) cycle
                if (depth >= fb%z_buffer(px, py)) cycle

                wp = vec3_create( &
                    w0 * world_v(1)%x + w1 * world_v(2)%x + &
                    w2 * world_v(3)%x, &
                    w0 * world_v(1)%y + w1 * world_v(2)%y + &
                    w2 * world_v(3)%y, &
                    w0 * world_v(1)%z + w1 * world_v(2)%z + &
                    w2 * world_v(3)%z)

                u_interp = w1
                v_interp = w2

                do k = 1, 3
                    out_val = shader_eval(prog, base01(k), &
                        base01(1), base01(2), base01(3), &
                        wp%x, wp%y, wp%z, u_interp, v_interp, &
                        ndl, t_sec)
                    out_val = min(1.0_dp, max(0.0_dp, out_val))
                    rgb(k) = min(255, max(0, nint(out_val * 255.0_dp)))
                end do

                fb%z_buffer(px, py) = depth
                fb%pixels(1, px, py) = rgb(1)
                fb%pixels(2, px, py) = rgb(2)
                fb%pixels(3, px, py) = rgb(3)
            end do
        end do
    end subroutine draw_triangle_shader

    subroutine framebuffer_save_ppm(fb, filename)
        type(FrameBuffer), intent(in) :: fb
        character(len=*), intent(in) :: filename
        integer :: u, x, y

        open(newunit=u, file=filename, status='replace', action='write')
        write(u, '(A)') 'P3'
        write(u, '(I0, 1X, I0)') fb%width, fb%height
        write(u, '(A)') '255'

        do y = 1, fb%height
            do x = 1, fb%width
                write(u, '(I3, 1X, I3, 1X, I3, 1X)', advance='no') &
                    fb%pixels(1, x, y), fb%pixels(2, x, y), fb%pixels(3, x, y)
            end do
            write(u, *)
        end do
        close(u)
    end subroutine framebuffer_save_ppm

end module renderer_3d
