! camera_ortho.f90 -- orthographic camera (MASTER-PLAN parity row 3).
!
! Conventions (verified against src/math_3d.f90 and src/renderer.f90,
! not assumed):
!   * mat4 storage/indexing follows math_3d exactly: element m(i,j) is
!     row i, column j in the mathematical matrix, i.e. translation lives
!     in m(1,4), m(2,4), m(3,4) (see mat4_translation / mat4_look_at) and
!     mat4_transform_vec3 computes r_i = sum_j m(i,j) * v_j (+ m(i,4)*w).
!     mat4_perspective uses the same indexing: p%m(3,3), p%m(3,4) carry
!     the depth scale/offset and p%m(4,3) = -1.
!   * View space: x right, y up, camera looks down -z (mat4_look_at).
!   * NDC: x, y, z all in [-1, 1].  Depth: a view-space point on the
!     near plane (z = -near) maps to NDC z = -1 and a point on the far
!     plane (z = -far) maps to NDC z = +1 -- the same convention as
!     mat4_perspective.  renderer.f90 relies on it: it discards depth
!     outside [-1, 1] and keeps the smallest depth (depth < z_buffer),
!     so nearer fragments (more negative NDC z) win.
module camera_ortho_3d
    use math_3d
    implicit none
    private
    public :: CameraOrtho, mat4_ortho, ortho_proj_from_size
    public :: camera_ortho_init, camera_ortho_update_matrices
    public :: camera_ortho_set_aspect, camera_ortho_set_size
    public :: camera_ortho_is_valid

    type :: CameraOrtho
        type(vec3) :: position
        type(vec3) :: target
        type(vec3) :: up
        real(dp)   :: size          ! frustum height in world units
        real(dp)   :: aspect_ratio
        real(dp)   :: near_plane
        real(dp)   :: far_plane
        type(mat4) :: view_matrix
        type(mat4) :: proj_matrix
    end type CameraOrtho

contains

    ! Standard OpenGL-style orthographic projection, expressed in this
    ! engine's mat4 indexing (see header).  Maps the axis-aligned view
    ! box [left,right] x [bottom,top] x [-near,-far] onto the NDC cube
    ! [-1,1]^3: left/bottom/near -> -1, right/top/far -> +1.
    pure function mat4_ortho(left, right, bottom, top, near, far) result(p)
        real(dp), intent(in) :: left, right, bottom, top, near, far
        type(mat4) :: p

        p%m = 0.0_dp
        p%m(1, 1) = 2.0_dp / (right - left)
        p%m(2, 2) = 2.0_dp / (top - bottom)
        p%m(3, 3) = -2.0_dp / (far - near)
        p%m(1, 4) = -(right + left) / (right - left)
        p%m(2, 4) = -(top + bottom) / (top - bottom)
        p%m(3, 4) = -(far + near) / (far - near)
        p%m(4, 4) = 1.0_dp
    end function mat4_ortho

    ! Orthographic projection for a symmetric frustum whose height is
    ! `size` world units and whose width is size * aspect.
    pure function ortho_proj_from_size(size, aspect, near, far) result(p)
        real(dp), intent(in) :: size, aspect, near, far
        type(mat4) :: p
        real(dp) :: half_h, half_w

        half_h = size * 0.5_dp
        half_w = half_h * aspect
        p = mat4_ortho(-half_w, half_w, -half_h, half_h, near, far)
    end function ortho_proj_from_size

    ! Mirrors camera_init (camera_3d): up is fixed to (0,1,0), and the
    ! view/proj matrices are built immediately.
    subroutine camera_ortho_init(cam, pos, target, size, aspect, near, far)
        type(CameraOrtho), intent(out) :: cam
        type(vec3), intent(in) :: pos, target
        real(dp), intent(in) :: size, aspect, near, far

        cam%position = pos
        cam%target = target
        cam%up = vec3_create(0.0_dp, 1.0_dp, 0.0_dp)
        cam%size = size
        cam%aspect_ratio = aspect
        cam%near_plane = near
        cam%far_plane = far

        call camera_ortho_update_matrices(cam)
    end subroutine camera_ortho_init

    subroutine camera_ortho_update_matrices(cam)
        type(CameraOrtho), intent(inout) :: cam

        cam%view_matrix = mat4_look_at(cam%position, cam%target, cam%up)
        cam%proj_matrix = ortho_proj_from_size(cam%size, cam%aspect_ratio, &
                                               cam%near_plane, cam%far_plane)
    end subroutine camera_ortho_update_matrices

    subroutine camera_ortho_set_aspect(cam, aspect)
        type(CameraOrtho), intent(inout) :: cam
        real(dp), intent(in) :: aspect

        cam%aspect_ratio = aspect
        call camera_ortho_update_matrices(cam)
    end subroutine camera_ortho_set_aspect

    subroutine camera_ortho_set_size(cam, size)
        type(CameraOrtho), intent(inout) :: cam
        real(dp), intent(in) :: size

        cam%size = size
        call camera_ortho_update_matrices(cam)
    end subroutine camera_ortho_set_size

    pure function camera_ortho_is_valid(cam) result(valid)
        type(CameraOrtho), intent(in) :: cam
        logical :: valid

        valid = cam%size > 0.0_dp .and. cam%aspect_ratio > 0.0_dp .and. &
                cam%near_plane > 0.0_dp .and. cam%far_plane > cam%near_plane
    end function camera_ortho_is_valid

end module camera_ortho_3d
