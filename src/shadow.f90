! shadow.f90 -- real shadow maps: depth rendered from the light's point
! of view, then sampled per world-space point.
!
! The rasteriser mirrors src/renderer.f90 exactly: vertices are projected
! with a combined VP * model matrix via mat4_transform_vec3, mapped to
! pixel coordinates with
!   sx = int((ndc_x + 1) * 0.5 * size)
!   sy = int((1 - (ndc_y + 1) * 0.5) * size)
! culled with the same screen-space winding test
!   (sx2-sx1)*(sy3-sy1) - (sy2-sy1)*(sx3-sx1) <= 0  ->  skip
! and rasterised with the same integer barycentric weights, keeping the
! smallest NDC z in [-1, 1] per pixel.
!
! Note on that winding convention: as in the renderer, faces whose
! projected winding is non-positive are skipped, so for a closed mesh the
! depth recorded at a pixel may come from a far-side face rather than the
! light-facing one.  That is still a valid occluder depth: it lies between
! the light and anything hidden behind the mesh, so points behind the mesh
! compare as shadowed and points on the lit surface compare as lit (their
! z is smaller than any recorded occluder depth at their pixel).
module shadow_3d
    use math_3d
    use mesh_3d
    implicit none
    private
    public :: ShadowMap, shadow_begin, shadow_add_mesh, shadow_end, &
              shadow_factor, shadow_factor_pcf, shadow_free

    real(dp), parameter :: SHADOW_NO_DEPTH = 1.0e10_dp
    real(dp), parameter :: DEFAULT_BIAS = 0.002_dp

    type :: ShadowMap
        integer :: size = 0
        real(dp), allocatable :: depth(:, :)  ! (x, y), NDC z, SHADOW_NO_DEPTH = nothing hit
        type(mat4) :: light_vp
        logical :: ready = .false.
    end type ShadowMap

contains

    ! Start a new shadow map for a light at light_pos looking at
    ! light_target.  Allocates (or reallocates) the depth buffer, clears
    ! it to SHADOW_NO_DEPTH, and builds
    !   light_vp = perspective(fov_deg, aspect 1, near, far)
    !              * look_at(light_pos, light_target, up)
    ! with up = +Y, or +X when the light direction is (near-)parallel
    ! to +Y, where +Y would make look_at degenerate.
    subroutine shadow_begin(smap, light_pos, light_target, map_size, fov_deg, near, far)
        type(ShadowMap), intent(inout) :: smap
        type(vec3), intent(in) :: light_pos, light_target
        integer, intent(in) :: map_size
        real(dp), intent(in) :: fov_deg, near, far

        type(vec3) :: up, light_dir
        type(mat4) :: proj, view

        if (allocated(smap%depth)) deallocate(smap%depth)
        smap%size = max(1, map_size)
        allocate(smap%depth(smap%size, smap%size))
        smap%depth(:, :) = SHADOW_NO_DEPTH
        smap%ready = .false.

        light_dir = vec3_normalize(vec3_sub(light_target, light_pos))
        up = vec3_create(0.0_dp, 1.0_dp, 0.0_dp)
        if (abs(vec3_dot(light_dir, up)) > 0.999_dp) then
            up = vec3_create(1.0_dp, 0.0_dp, 0.0_dp)
        end if

        proj = mat4_perspective(deg2rad(fov_deg), 1.0_dp, near, far)
        view = mat4_look_at(light_pos, light_target, up)
        smap%light_vp = mat4_mult(proj, view)
    end subroutine shadow_begin

    ! Rasterise one mesh (transformed by model_matrix) into the depth
    ! buffer.  Accumulates across calls: call shadow_begin once, then
    ! shadow_add_mesh for every caster, then shadow_end.
    subroutine shadow_add_mesh(smap, target_mesh, model_matrix)
        type(ShadowMap), intent(inout) :: smap
        type(Mesh), intent(in) :: target_mesh
        type(mat4), intent(in) :: model_matrix

        type(mat4) :: vp_model
        type(Triangle) :: tri
        type(vec3) :: proj_v(3)
        integer :: i, sx(3), sy(3)
        real(dp) :: z(3)

        if (.not. allocated(smap%depth)) return
        if (smap%size <= 0) return

        vp_model = mat4_mult(smap%light_vp, model_matrix)

        do i = 1, target_mesh%num_triangles
            tri = target_mesh%triangles(i)

            proj_v(1) = mat4_transform_vec3(vp_model, tri%v(1), .true.)
            proj_v(2) = mat4_transform_vec3(vp_model, tri%v(2), .true.)
            proj_v(3) = mat4_transform_vec3(vp_model, tri%v(3), .true.)

            ! Same NDC -> pixel mapping as renderer.f90.
            sx(1) = int((proj_v(1)%x + 1.0_dp) * 0.5_dp * smap%size)
            sy(1) = int((1.0_dp - (proj_v(1)%y + 1.0_dp) * 0.5_dp) * smap%size)
            z(1)  = proj_v(1)%z

            sx(2) = int((proj_v(2)%x + 1.0_dp) * 0.5_dp * smap%size)
            sy(2) = int((1.0_dp - (proj_v(2)%y + 1.0_dp) * 0.5_dp) * smap%size)
            z(2)  = proj_v(2)%z

            sx(3) = int((proj_v(3)%x + 1.0_dp) * 0.5_dp * smap%size)
            sy(3) = int((1.0_dp - (proj_v(3)%y + 1.0_dp) * 0.5_dp) * smap%size)
            z(3)  = proj_v(3)%z

            ! Same backface / winding convention as renderer.f90.
            if ((sx(2) - sx(1)) * (sy(3) - sy(1)) - (sy(2) - sy(1)) * (sx(3) - sx(1)) <= 0) cycle

            call rasterize_depth(smap, sx, sy, z)
        end do
    end subroutine shadow_add_mesh

    ! Barycentric depth rasteriser, mirroring draw_triangle_rgb in
    ! renderer.f90 but writing NDC depth instead of colour.
    subroutine rasterize_depth(smap, x, y, z)
        type(ShadowMap), intent(inout) :: smap
        integer, intent(in) :: x(3), y(3)
        real(dp), intent(in) :: z(3)

        integer :: min_x, max_x, min_y, max_y, px, py
        real(dp) :: w0, w1, w2, denom, depth

        min_x = max(1, min(x(1), min(x(2), x(3))))
        max_x = min(smap%size, max(x(1), max(x(2), x(3))))
        min_y = max(1, min(y(1), min(y(2), y(3))))
        max_y = min(smap%size, max(y(1), max(y(2), y(3))))

        denom = real((y(2) - y(3)) * (x(1) - x(3)) + (x(3) - x(2)) * (y(1) - y(3)), dp)
        if (abs(denom) < 1.0e-6_dp) return

        do py = min_y, max_y
            do px = min_x, max_x
                w0 = real((y(2) - y(3)) * (px - x(3)) + (x(3) - x(2)) * (py - y(3)), dp) / denom
                w1 = real((y(3) - y(1)) * (px - x(3)) + (x(1) - x(3)) * (py - y(3)), dp) / denom
                w2 = 1.0_dp - w0 - w1

                if (w0 >= 0.0_dp .and. w1 >= 0.0_dp .and. w2 >= 0.0_dp) then
                    depth = w0 * z(1) + w1 * z(2) + w2 * z(3)
                    if (depth >= -1.0_dp .and. depth <= 1.0_dp .and. &
                        depth < smap%depth(px, py)) then
                        smap%depth(px, py) = depth
                    end if
                end if
            end do
        end do
    end subroutine rasterize_depth

    subroutine shadow_end(smap)
        type(ShadowMap), intent(inout) :: smap
        smap%ready = .true.
    end subroutine shadow_end

    ! 1.0 = lit, 0.0 = shadowed.  A map that is not ready (never built,
    ! or freed) lights everything, as does any point whose light-space
    ! projection falls outside the [-1, 1]^3 clip cube.
    pure function shadow_factor(smap, world_pos, bias) result(f)
        type(ShadowMap), intent(in) :: smap
        type(vec3), intent(in) :: world_pos
        real(dp), intent(in), optional :: bias
        real(dp) :: f

        type(vec3) :: proj
        real(dp) :: b
        integer :: px, py

        f = 1.0_dp
        if (.not. smap%ready) return
        if (.not. allocated(smap%depth)) return
        if (smap%size <= 0) return

        b = DEFAULT_BIAS
        if (present(bias)) b = bias

        proj = mat4_transform_vec3(smap%light_vp, world_pos, .true.)
        if (abs(proj%x) > 1.0_dp .or. abs(proj%y) > 1.0_dp .or. &
            abs(proj%z) > 1.0_dp) return

        call world_to_pixel(smap, proj, px, py)
        if (proj%z <= smap%depth(px, py) + b) then
            f = 1.0_dp
        else
            f = 0.0_dp
        end if
    end function shadow_factor

    ! Soft-shadow variant (`shadow: soft`): averages the binary test
    ! over the 3x3 neighbourhood of the sample pixel, so points near a
    ! shadow edge return a fractional factor strictly between 0 and 1.
    pure function shadow_factor_pcf(smap, world_pos, bias) result(f)
        type(ShadowMap), intent(in) :: smap
        type(vec3), intent(in) :: world_pos
        real(dp), intent(in), optional :: bias
        real(dp) :: f

        type(vec3) :: proj
        real(dp) :: b, lit_count
        integer :: px, py, dx, dy, tx, ty

        f = 1.0_dp
        if (.not. smap%ready) return
        if (.not. allocated(smap%depth)) return
        if (smap%size <= 0) return

        b = DEFAULT_BIAS
        if (present(bias)) b = bias

        proj = mat4_transform_vec3(smap%light_vp, world_pos, .true.)
        if (abs(proj%x) > 1.0_dp .or. abs(proj%y) > 1.0_dp .or. &
            abs(proj%z) > 1.0_dp) return

        call world_to_pixel(smap, proj, px, py)
        lit_count = 0.0_dp
        do dy = -1, 1
            do dx = -1, 1
                tx = min(smap%size, max(1, px + dx))
                ty = min(smap%size, max(1, py + dy))
                if (proj%z <= smap%depth(tx, ty) + b) lit_count = lit_count + 1.0_dp
            end do
        end do
        f = lit_count / 9.0_dp
    end function shadow_factor_pcf

    ! Same NDC -> pixel mapping as the rasteriser (and renderer.f90),
    ! clamped into [1, size].
    pure subroutine world_to_pixel(smap, proj, px, py)
        type(ShadowMap), intent(in) :: smap
        type(vec3), intent(in) :: proj
        integer, intent(out) :: px, py

        px = int((proj%x + 1.0_dp) * 0.5_dp * smap%size)
        py = int((1.0_dp - (proj%y + 1.0_dp) * 0.5_dp) * smap%size)
        px = min(smap%size, max(1, px))
        py = min(smap%size, max(1, py))
    end subroutine world_to_pixel

    subroutine shadow_free(smap)
        type(ShadowMap), intent(inout) :: smap
        if (allocated(smap%depth)) deallocate(smap%depth)
        smap%size = 0
        smap%ready = .false.
    end subroutine shadow_free

end module shadow_3d
