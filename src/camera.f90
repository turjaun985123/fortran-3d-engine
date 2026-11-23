module camera_3d
    use math_3d
    use, intrinsic :: iso_fortran_env, only: error_unit
    implicit none
    private
    public :: Camera, camera_init, camera_update_matrices
    public :: camera_set_aspect, camera_is_valid, camera_init_checked

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

    subroutine camera_set_aspect(cam, aspect)
        type(Camera), intent(inout) :: cam
        real(dp), intent(in) :: aspect

        cam%aspect_ratio = aspect
        call camera_update_matrices(cam)
    end subroutine camera_set_aspect

    pure function camera_is_valid(cam) result(valid)
        type(Camera), intent(in) :: cam
        logical :: valid

        valid = cam%fov_deg > 0.0_dp .and. cam%fov_deg < 180.0_dp .and. &
                cam%near_plane > 0.0_dp .and. cam%far_plane > cam%near_plane .and. &
                cam%aspect_ratio > 0.0_dp
    end function camera_is_valid

    subroutine camera_init_checked(cam, pos, target, fov_deg, aspect, near, far, ok)
        type(Camera), intent(out) :: cam
        type(vec3), intent(in) :: pos, target
        real(dp), intent(in) :: fov_deg, aspect, near, far
        logical, intent(out) :: ok

        ok = fov_deg > 0.0_dp .and. fov_deg < 180.0_dp .and. &
             near > 0.0_dp .and. far > near .and. aspect > 0.0_dp
        if (ok) then
            call camera_init(cam, pos, target, fov_deg, aspect, near, far)
        else
            ! M1 (v3.0 Phase 0): this default substitution used to be
            ! silent; surface it on stderr like the engine's other
            ! '<module>: warning:' diagnostics (scene.f90 style).
            write(error_unit, '(A)') 'camera: warning: ' // &
                'camera_init_checked: invalid camera parameters; ' // &
                'using default camera (fov 60, aspect 4/3, ' // &
                'near 0.1, far 100)'
            call camera_init(cam, pos, target, 60.0_dp, 4.0_dp / 3.0_dp, 0.1_dp, 100.0_dp)
        end if
    end subroutine camera_init_checked

end module camera_3d
