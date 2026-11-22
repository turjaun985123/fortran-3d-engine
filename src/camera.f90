module camera_3d
    use math_3d
    implicit none
    private
    public :: Camera, camera_init, camera_update_matrices

    type :: Camera
        type(vec3) :: position
        type(vec3) :: target
        type(vec3) :: up
        real(dp)   :: fov_deg
        real(dp)   :: aspect_ratio
        real(dp)   :: near_plane
        real(dp)   :: far_plane
        type(mat4) :: view_matrix
        type(mat4) :: proj_matrix
    end type Camera

contains

    subroutine camera_init(cam, pos, target, fov_deg, aspect, near, far)
        type(Camera), intent(out) :: cam
        type(vec3), intent(in) :: pos, target
        real(dp), intent(in) :: fov_deg, aspect, near, far

        cam%position = pos
        cam%target = target
        cam%up = vec3_create(0.0_dp, 1.0_dp, 0.0_dp)
        cam%fov_deg = fov_deg
        cam%aspect_ratio = aspect
        cam%near_plane = near
        cam%far_plane = far

        call camera_update_matrices(cam)
    end subroutine camera_init

    subroutine camera_update_matrices(cam)
        type(Camera), intent(inout) :: cam
        real(dp) :: fov_rad

        fov_rad = cam%fov_deg * PI / 180.0_dp
        cam%view_matrix = mat4_look_at(cam%position, cam%target, cam%up)
        cam%proj_matrix = mat4_perspective(fov_rad, cam%aspect_ratio, cam%near_plane, cam%far_plane)
    end subroutine camera_update_matrices

end module camera_3d
