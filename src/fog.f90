! fog.f90 -- distance fog, Three.js Fog / FogExp2 parity.
!
! Dependency direction: fog_3d uses renderer_3d (for FrameBuffer);
! renderer_3d never uses fog_3d, so there is no module cycle.
!
! Semantics follow Three.js:
!   * Linear fog (THREE.Fog): the fog factor is 0 at/below the fog near
!     distance, 1 at/beyond the fog far distance, and linear in between.
!     The factor is the FOG amount: final = mix(colour, fog_colour, f).
!   * Exponential-squared fog (THREE.FogExp2):
!         f = 1 - exp(-(density * distance)**2)
! Both factors are clamped to [0, 1].
!
! Distances are reconstructed from the framebuffer's NDC depth (see
! view_distance_from_ndc); pixels whose z_buffer still holds the
! background sentinel (>= 1e9) are left untouched, since the background
! is already the scene background colour.
module fog_3d
    use math_3d, only: dp
    use renderer_3d, only: FrameBuffer
    implicit none
    private
    public :: fog_factor_linear, fog_factor_exp2, &
              view_distance_from_ndc, fog_blend, fog_apply

    ! Fog modes for fog_apply.
    integer, parameter, public :: FOG_MODE_LINEAR = 1
    integer, parameter, public :: FOG_MODE_EXP2   = 2

    ! z_buffer sentinel at/above which a pixel counts as background
    ! (renderer clears z_buffer to 1.0e10).
    real(dp), parameter :: BG_Z = 1.0e9_dp

contains

    ! Linear fog factor (Three.js Fog): 0 at dist <= near, 1 at
    ! dist >= far, linear between, clamped to [0, 1].
    pure function fog_factor_linear(dist, near, far) result(f)
        real(dp), intent(in) :: dist, near, far
        real(dp) :: f

        if (dist <= near) then
            f = 0.0_dp
        else if (dist >= far) then
            f = 1.0_dp
        else
            f = (dist - near) / (far - near)
        end if
        f = min(1.0_dp, max(0.0_dp, f))
    end function fog_factor_linear

    ! Exponential-squared fog factor (Three.js FogExp2):
    !   f = 1 - exp(-(density * dist)**2), clamped to [0, 1].
    pure function fog_factor_exp2(dist, density) result(f)
        real(dp), intent(in) :: dist, density
        real(dp) :: f

        f = 1.0_dp - exp(-(density * dist) ** 2)
        f = min(1.0_dp, max(0.0_dp, f))
    end function fog_factor_exp2

    ! Reconstruct view depth from NDC depth z in [-1, 1] for a
    ! perspective projection with the given near/far planes:
    !   d = (2 * near * far) / (far + near - z * (far - near))
    ! This is the view-axis depth (distance along the camera forward
    ! axis), used as the fog distance -- the standard approximation
    ! (exact on the view axis, slightly short toward the corners).
    pure function view_distance_from_ndc(z, near, far) result(d)
        real(dp), intent(in) :: z, near, far
        real(dp) :: d

        d = (2.0_dp * near * far) / (far + near - z * (far - near))
    end function view_distance_from_ndc

    ! Integer RGB mix: out = rgb * (1 - f) + fog_rgb * f, per channel,
    ! rounded to nearest and clamped to [0, 255]. f is clamped to [0, 1].
    pure function fog_blend(rgb, fog_rgb, f) result(out)
        integer, intent(in) :: rgb(3), fog_rgb(3)
        real(dp), intent(in) :: f
        integer :: out(3)
        real(dp) :: fc
        integer :: k

        fc = min(1.0_dp, max(0.0_dp, f))
        do k = 1, 3
            out(k) = nint(real(rgb(k), dp) * (1.0_dp - fc) + &
                          real(fog_rgb(k), dp) * fc)
            out(k) = min(255, max(0, out(k)))
        end do
    end function fog_blend

    ! Apply fog in place to every covered pixel of fb.
    !   mode = 1 (linear): p1 = fog near, p2 = fog far
    !   mode = 2 (exp2):   p1 = density,  p2 ignored
    ! cam_near / cam_far are the camera planes used to reconstruct the
    ! view distance from each pixel's NDC depth. Background pixels
    ! (z_buffer >= 1e9) are untouched. Unknown mode is a no-op.
    subroutine fog_apply(fb, mode, p1, p2, fog_color, cam_near, cam_far)
        type(FrameBuffer), intent(inout) :: fb
        integer, intent(in) :: mode
        real(dp), intent(in) :: p1, p2
        integer, intent(in) :: fog_color(3)
        real(dp), intent(in) :: cam_near, cam_far

        integer :: x, y
        real(dp) :: dist, f

        if (mode /= FOG_MODE_LINEAR .and. mode /= FOG_MODE_EXP2) return

        do y = 1, fb%height
            do x = 1, fb%width
                if (fb%z_buffer(x, y) >= BG_Z) cycle
                dist = view_distance_from_ndc(fb%z_buffer(x, y), cam_near, cam_far)
                select case (mode)
                case (FOG_MODE_LINEAR)
                    f = fog_factor_linear(dist, p1, p2)
                case default ! FOG_MODE_EXP2
                    f = fog_factor_exp2(dist, p1)
                end select
                fb%pixels(:, x, y) = fog_blend(fb%pixels(:, x, y), fog_color, f)
            end do
        end do
    end subroutine fog_apply

end module fog_3d
