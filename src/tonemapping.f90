! tonemapping.f90 -- optional tone mapping for rendered framebuffers.
!
! Parity-matrix row 25: ACES / Reinhard / none, selected by one scene
! keyword, default = none.  The default matters: TM_NONE is the legacy
! golden path, and the legacy renderer never calls this module, so the
! default output stays deterministic and bit-identical.  Even when this
! module IS called with TM_NONE, tonemap_apply returns immediately and
! tonemap_scalar is the identity on 0..1, so nothing changes.
!
! Inputs are linear values, nominally 0..~1+ (values above 1 are the
! point of tone mapping: Reinhard and ACES roll them off towards 1).
module tonemapping_3d
    use math_3d, only: dp
    use renderer_3d, only: FrameBuffer
    implicit none
    private

    public :: TM_NONE, TM_REINHARD, TM_ACES
    public :: tonemap_scalar, tonemap_rgb, tonemap_apply, &
              tonemap_mode_from_name

    integer, parameter :: TM_NONE     = 0
    integer, parameter :: TM_REINHARD = 1
    integer, parameter :: TM_ACES     = 2

contains

    ! Map one linear scalar through the selected curve.
    !   xe = x * exposure  (exposure is applied here, once)
    !   TM_REINHARD: y = xe / (1 + xe)
    !   TM_ACES:     y = clamp(xe*(2.51*xe + 0.03) /
    !                          (xe*(2.43*xe + 0.59) + 0.14), 0, 1)
    !                (the standard Narkowicz ACES fitted curve)
    !   TM_NONE or any unknown mode: y = clamp(x, 0, 1).
    !                NOTE: the none path ignores exposure entirely --
    !                it is a plain clamp of the input, so that the
    !                legacy path stays exactly the identity on 0..1.
    pure function tonemap_scalar(mode, x, exposure) result(y)
        integer, intent(in) :: mode
        real(dp), intent(in) :: x, exposure
        real(dp) :: y
        real(dp) :: xe

        select case (mode)
        case (TM_REINHARD)
            xe = x * exposure
            y = xe / (1.0_dp + xe)
        case (TM_ACES)
            xe = x * exposure
            y = min(max((xe * (2.51_dp * xe + 0.03_dp)) / &
                        (xe * (2.43_dp * xe + 0.59_dp) + 0.14_dp), &
                        0.0_dp), 1.0_dp)
        case default
            y = min(max(x, 0.0_dp), 1.0_dp)
        end select
    end function tonemap_scalar

    ! Channel-wise tonemap_scalar over an RGB triple (real, 0..1 nominal).
    pure function tonemap_rgb(mode, rgb, exposure) result(out)
        integer, intent(in) :: mode
        real(dp), intent(in) :: rgb(3), exposure
        real(dp) :: out(3)
        integer :: k

        do k = 1, 3
            out(k) = tonemap_scalar(mode, rgb(k), exposure)
        end do
    end function tonemap_rgb

    ! Apply tone mapping to every pixel of a framebuffer, in place:
    !   0..255 integer -> /255 -> tonemap_rgb -> *255 -> int, clamped.
    ! The z-buffer is never touched.
    ! TM_NONE returns immediately, before any floating-point round-trip,
    ! so the buffer is left BIT-IDENTICAL.
    subroutine tonemap_apply(fb, mode, exposure)
        type(FrameBuffer), intent(inout) :: fb
        integer, intent(in) :: mode
        real(dp), intent(in) :: exposure

        real(dp) :: rgb(3), mapped(3)
        integer :: x, y, k

        if (mode == TM_NONE) return

        do y = 1, fb%height
            do x = 1, fb%width
                do k = 1, 3
                    rgb(k) = real(fb%pixels(k, x, y), dp) / 255.0_dp
                end do
                mapped = tonemap_rgb(mode, rgb, exposure)
                do k = 1, 3
                    fb%pixels(k, x, y) = min(255, max(0, &
                        int(mapped(k) * 255.0_dp)))
                end do
            end do
        end do
    end subroutine tonemap_apply

    ! Scene-keyword mapping: 'aces' -> TM_ACES, 'reinhard' -> TM_REINHARD,
    ! anything else (including 'none' and unknown names) -> TM_NONE.
    function tonemap_mode_from_name(name) result(mode)
        character(len=*), intent(in) :: name
        integer :: mode

        select case (trim(name))
        case ('aces')
            mode = TM_ACES
        case ('reinhard')
            mode = TM_REINHARD
        case default
            mode = TM_NONE
        end select
    end function tonemap_mode_from_name

end module tonemapping_3d
