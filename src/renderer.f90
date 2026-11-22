module renderer_3d
    use math_3d
    use mesh_3d
    use camera_3d
    use material_3d
    use material_pbr_3d, only: MaterialPBR
    use texture_3d, only: TextureImage, texture_sample, prim_uv
    use lighting_3d, only: LightSet, shade_rgb
    use shadow_3d, only: ShadowMap, shadow_factor, shadow_factor_pcf
    implicit none
    private
    public :: FrameBuffer, framebuffer_init, framebuffer_clear, &
              framebuffer_render_mesh, framebuffer_render_mesh_mat, &
              framebuffer_render_mesh_env, &
              framebuffer_save_ppm

    type :: FrameBuffer
        integer :: width
        integer :: height
        integer, allocatable :: pixels(:, :, :) ! (3, width, height) RGB
        real(dp), allocatable :: z_buffer(:, :)  ! (width, height)
    end type FrameBuffer

contains

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
        integer :: i, k, sx(3), sy(3)
        real(dp) :: z(3)

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
            call draw_triangle_rgb(fb, sx, sy, z, rgb)
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

        model_view = mat4_mult(cam%view_matrix, model_matrix)
        mvp = mat4_mult(cam%proj_matrix, model_view)

        do i = 1, target_mesh%num_triangles
            tri = target_mesh%triangles(i)

            world_v(1) = mat4_transform_vec3(model_matrix, tri%v(1), .true.)
            world_v(2) = mat4_transform_vec3(model_matrix, tri%v(2), .true.)
            world_v(3) = mat4_transform_vec3(model_matrix, tri%v(3), .true.)
            normal_world = compute_triangle_normal(world_v(1), world_v(2), &
                                                   world_v(3))

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
                                   normal_world, cam, lights, pbr, tex, &
                                   smap, shadow_mode)
        end do
    end subroutine framebuffer_render_mesh_env

    subroutine draw_triangle_env(fb, x, y, z, world_v, uv, tri, &
                                 normal_world, cam, lights, pbr, tex, &
                                 smap, shadow_mode)
        type(FrameBuffer), intent(inout) :: fb
        integer, intent(in) :: x(3), y(3)
        real(dp), intent(in) :: z(3), uv(2, 3)
        type(vec3), intent(in) :: world_v(3), normal_world
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
        type(vec3) :: wp
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

                rgb = shade_rgb(base_rgb, normal_world, wp, &
                                cam%position, lights, pbr, sfac)

                fb%z_buffer(px, py) = depth
                fb%pixels(1, px, py) = rgb(1)
                fb%pixels(2, px, py) = rgb(2)
                fb%pixels(3, px, py) = rgb(3)
            end do
        end do
    end subroutine draw_triangle_env

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
