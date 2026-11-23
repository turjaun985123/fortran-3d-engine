module camera_3d
    use math_3d
    use, intrinsic :: iso_fortran_env, only: error_unit
    implicit none
    private
    public :: Camera, camera_init, camera_update_matrices
    public :: camera_set_aspect, camera_is_valid, camera_init_checked
    public :: camera_view_status
    public :: CAMERA_VIEW_CLEAN, CAMERA_VIEW_DEGENERATE

    ! Status codes reported by camera_view_status /
    ! camera_init_checked (v3.0 Phase 5, completing the Phase 0 M1
    ! diagnostic path):
    !   CAMERA_VIEW_CLEAN (0)     -- view direction is well defined
    !                                and not (anti-)parallel to up.
    !   CAMERA_VIEW_DEGENERATE (1) -- eye == target (no view
    !                                direction at all), or the view
    !                                direction is (anti-)parallel to
    !                                up, in which case mat4_look_at
    !                                substitutes its fallback up
    !                                (0,0,+1) / (0,0,-1).
    integer, parameter :: CAMERA_VIEW_CLEAN = 0
    integer, parameter :: CAMERA_VIEW_DEGENERATE = 1

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

    !> Classify a camera pose with the exact thresholds
    !! mat4_look_at uses for its Phase 0 (M1) guard, without
    !! building any matrix: CAMERA_VIEW_DEGENERATE when pos ==
    !! target (zero view direction) or when the view direction is
    !! (anti-)parallel to up (a zero up first takes the same
    !! (0,1,0) default mat4_look_at applies).  Purely a diagnostic
    !! classification -- it changes no numeric behaviour anywhere.
    pure function camera_view_status(pos, target, up) result(status)
        type(vec3), intent(in) :: pos, target, up
        integer :: status
        type(vec3) :: dir, up_eff
        real(dp) :: f_dot_up

        status = CAMERA_VIEW_CLEAN
        dir = vec3_sub(target, pos)
        if (vec3_norm(dir) <= 1.0e-12_dp) then
            status = CAMERA_VIEW_DEGENERATE
            return
        end if
        up_eff = up
        if (vec3_norm(up_eff) <= 1.0e-12_dp) &
            up_eff = vec3_create(0.0_dp, 1.0_dp, 0.0_dp)
        f_dot_up = vec3_dot(vec3_normalize(dir), &
                            vec3_normalize(up_eff))
        if (abs(f_dot_up) > 1.0_dp - 1.0e-10_dp) &
            status = CAMERA_VIEW_DEGENERATE
    end function camera_view_status

    !> camera_init with parameter validation.  The optional
    !! `status` argument (v3.0 Phase 5) reports the M1 diagnostic
    !! for the pose actually built: CAMERA_VIEW_CLEAN (0) or
    !! CAMERA_VIEW_DEGENERATE (1) when eye == target or the view
    !! direction is (anti-)parallel to the camera's up (0,1,0) --
    !! the case where mat4_look_at substitutes its fallback up.
    !! It is OPTIONAL so pre-Phase-5 callers compile unchanged.
    !! Reporting only: the matrices built are exactly those the
    !! pre-Phase-5 code built (ADR-1).
    subroutine camera_init_checked(cam, pos, target, fov_deg, aspect, near, far, ok, status)
        type(Camera), intent(out) :: cam
        type(vec3), intent(in) :: pos, target
        real(dp), intent(in) :: fov_deg, aspect, near, far
        logical, intent(out) :: ok
        integer, intent(out), optional :: status

        if (present(status)) status = camera_view_status( &
            pos, target, vec3_create(0.0_dp, 1.0_dp, 0.0_dp))
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
