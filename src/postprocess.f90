! postprocess.f90 -- native post-processing for rendered framebuffers.
!
! Parity-matrix row 30: post-processing filters applied to a
! renderer_3d FrameBuffer AFTER rendering.  Post-processing is opt-in
! only: nothing in the legacy renderer calls this module, so the golden
! render stays bit-identical unless a caller explicitly applies a filter.
!
! Mirror contract: runtime/f3d-post.js implements IDENTICAL math.
! Every formula below is written in its simplest form and documented
! exactly, so the JS mirror can match bit-for-bit on the integer
! results.  Shared conventions for ALL filters:
!   * Pixels are integers 0..255, channels (R, G, B) = pixels(1..3, x, y).
!   * Every computed channel is rounded to nearest (nint) and clamped
!     to 0..255 exactly once, at the end of that filter, unless a
!     filter below says otherwise.
!   * Luminance (real, 0..255 scale, NOT rounded before use):
!         lum = 0.299*R + 0.587*G + 0.114*B
!   * The z-buffer is never touched.
!   * Filter names are case-insensitive; an unknown name is a no-op.
!
! Filters (name -> semantics; amount is a real):
!   blur      One 3x3 box-blur pass per int(amount) passes, only when
!             amount >= 1 (otherwise no-op).  Each pass reads a snapshot
!             of the previous pass (never in-place).  Neighbour indices
!             are clamped to the image edges.  Integer-exact:
!                 out = (sum_of_9_samples + 4) / 9   (integer division)
!   bloom     Bloom-APPROXIMATION (honest label: no blur / no HDR
!             buffer -- a per-pixel threshold lift only):
!                 lum01  = lum / 255
!                 excess = max(0, lum01 - 0.75) * amount
!                 out    = round_and_clamp(c + 255 * excess)
!             The same excess is added to all three channels.
!   vignette  Squared normalised distance from the centre:
!                 nx = (2*(x-1)/(W-1) - 1)  if W > 1, else 0
!                 ny = (2*(y-1)/(H-1) - 1)  if H > 1, else 0
!                 d2 = (nx*nx + ny*ny) / 2      (0 centre, 1 corners)
!                 scale = 1 - amount * d2
!                 out = round_and_clamp(c * scale)
!   gamma     Only for amount > 0 (amount <= 0 is a no-op;
!             amount == 1 is an exact no-op):
!                 out = round_and_clamp(255 * (c/255)**(1/amount))
!   grayscale Blend toward luminance, blend factor a clamped to [0,1]:
!                 a = min(1, max(0, amount))
!                 out = round_and_clamp((1-a)*c + a*lum)
!   sepia     Blend toward the sepia matrix result, a clamped as above.
!             The sepia target is clamped to 0..255 (as a real, before
!             blending, not rounded):
!                 sr = min(255, 0.393*R + 0.769*G + 0.189*B)
!                 sg = min(255, 0.349*R + 0.686*G + 0.168*B)
!                 sb = min(255, 0.272*R + 0.534*G + 0.131*B)
!                 out = round_and_clamp((1-a)*c + a*s_c)
module postprocess_3d
    use math_3d, only: dp
    use renderer_3d, only: FrameBuffer
    implicit none
    private

    public :: post_apply, post_apply_chain

contains

    ! Round to nearest and clamp to 0..255.
    pure function clamp_round(v) result(o)
        real(dp), intent(in) :: v
        integer :: o

        o = min(255, max(0, nint(v)))
    end function clamp_round

    ! Luminance on the 0..255 scale (real, unrounded).
    pure function luminance(r, g, b) result(lum)
        integer, intent(in) :: r, g, b
        real(dp) :: lum

        lum = 0.299_dp * real(r, dp) + 0.587_dp * real(g, dp) + &
              0.114_dp * real(b, dp)
    end function luminance

    ! Lower-case (ASCII A-Z only) copy of a name, for case-insensitive
    ! matching against the filter names.
    function lower_name(name) result(out)
        character(len=*), intent(in) :: name
        character(len=len_trim(name)) :: out
        integer :: i, c

        out = trim(name)
        do i = 1, len(out)
            c = iachar(out(i:i))
            if (c >= iachar('A') .and. c <= iachar('Z')) &
                out(i:i) = achar(c - iachar('A') + iachar('a'))
        end do
    end function lower_name

    ! Apply one named filter to fb, in place.  Unknown name = no-op.
    subroutine post_apply(fb, name, amount)
        type(FrameBuffer), intent(inout) :: fb
        character(len=*), intent(in) :: name
        real(dp), intent(in) :: amount

        select case (lower_name(name))
        case ('blur')
            call apply_blur(fb, amount)
        case ('bloom')
            call apply_bloom(fb, amount)
        case ('vignette')
            call apply_vignette(fb, amount)
        case ('gamma')
            call apply_gamma(fb, amount)
        case ('grayscale')
            call apply_grayscale(fb, amount)
        case ('sepia')
            call apply_sepia(fb, amount)
        case default
            return ! unknown name: no-op
        end select
    end subroutine post_apply

    ! Apply n filters in order: names(1), names(2), ..., names(n).
    ! Order matters (e.g. blur-then-gamma /= gamma-then-blur).
    subroutine post_apply_chain(fb, names, amounts, n)
        type(FrameBuffer), intent(inout) :: fb
        character(len=*), intent(in) :: names(:)
        real(dp), intent(in) :: amounts(:)
        integer, intent(in) :: n
        integer :: i

        do i = 1, n
            call post_apply(fb, names(i), amounts(i))
        end do
    end subroutine post_apply_chain

    ! 3x3 box blur: one pass per int(amount) passes (amount >= 1 only).
    ! Integer-exact: out = (sum + 4) / 9 with clamped edge indices,
    ! computed from a snapshot of the previous pass.
    subroutine apply_blur(fb, amount)
        type(FrameBuffer), intent(inout) :: fb
        real(dp), intent(in) :: amount

        integer, allocatable :: tmp(:, :, :)
        integer :: passes, p, x, y, k, dx, dy, xc, yc, s

        if (amount < 1.0_dp) return
        passes = int(amount)
        allocate(tmp(3, fb%width, fb%height))
        do p = 1, passes
            do y = 1, fb%height
                do x = 1, fb%width
                    do k = 1, 3
                        s = 0
                        do dy = -1, 1
                            yc = min(fb%height, max(1, y + dy))
                            do dx = -1, 1
                                xc = min(fb%width, max(1, x + dx))
                                s = s + fb%pixels(k, xc, yc)
                            end do
                        end do
                        tmp(k, x, y) = (s + 4) / 9
                    end do
                end do
            end do
            fb%pixels = tmp
        end do
        deallocate(tmp)
    end subroutine apply_blur

    ! Bloom-approx: per-pixel threshold lift (no blur, no HDR buffer).
    !   excess = max(0, lum/255 - 0.75) * amount, added (as 255*excess)
    !   to every channel.
    subroutine apply_bloom(fb, amount)
        type(FrameBuffer), intent(inout) :: fb
        real(dp), intent(in) :: amount

        integer :: x, y, k
        real(dp) :: excess

        do y = 1, fb%height
            do x = 1, fb%width
                excess = max(0.0_dp, luminance(fb%pixels(1, x, y), &
                    fb%pixels(2, x, y), fb%pixels(3, x, y)) / 255.0_dp &
                    - 0.75_dp) * amount
                do k = 1, 3
                    fb%pixels(k, x, y) = clamp_round( &
                        real(fb%pixels(k, x, y), dp) + 255.0_dp * excess)
                end do
            end do
        end do
    end subroutine apply_bloom

    ! Vignette: out = c * (1 - amount * d2); see header for nx/ny/d2.
    subroutine apply_vignette(fb, amount)
        type(FrameBuffer), intent(inout) :: fb
        real(dp), intent(in) :: amount

        integer :: x, y, k
        real(dp) :: nx, ny, d2, scale

        do y = 1, fb%height
            if (fb%height > 1) then
                ny = 2.0_dp * real(y - 1, dp) / real(fb%height - 1, dp) &
                     - 1.0_dp
            else
                ny = 0.0_dp
            end if
            do x = 1, fb%width
                if (fb%width > 1) then
                    nx = 2.0_dp * real(x - 1, dp) &
                         / real(fb%width - 1, dp) - 1.0_dp
                else
                    nx = 0.0_dp
                end if
                d2 = (nx * nx + ny * ny) / 2.0_dp
                scale = 1.0_dp - amount * d2
                do k = 1, 3
                    fb%pixels(k, x, y) = clamp_round( &
                        real(fb%pixels(k, x, y), dp) * scale)
                end do
            end do
        end do
    end subroutine apply_vignette

    ! Gamma: out = 255 * (c/255)**(1/amount), amount > 0 only.
    subroutine apply_gamma(fb, amount)
        type(FrameBuffer), intent(inout) :: fb
        real(dp), intent(in) :: amount

        integer :: x, y, k
        real(dp) :: inv

        if (amount <= 0.0_dp) return
        if (amount == 1.0_dp) return ! exact no-op
        inv = 1.0_dp / amount
        do y = 1, fb%height
            do x = 1, fb%width
                do k = 1, 3
                    fb%pixels(k, x, y) = clamp_round(255.0_dp * &
                        (real(fb%pixels(k, x, y), dp) / 255.0_dp) ** inv)
                end do
            end do
        end do
    end subroutine apply_gamma

    ! Grayscale: blend toward luminance with a = clamp(amount, 0, 1).
    subroutine apply_grayscale(fb, amount)
        type(FrameBuffer), intent(inout) :: fb
        real(dp), intent(in) :: amount

        integer :: x, y, k
        real(dp) :: a, lum

        a = min(1.0_dp, max(0.0_dp, amount))
        if (a <= 0.0_dp) return
        do y = 1, fb%height
            do x = 1, fb%width
                lum = luminance(fb%pixels(1, x, y), fb%pixels(2, x, y), &
                                fb%pixels(3, x, y))
                do k = 1, 3
                    fb%pixels(k, x, y) = clamp_round( &
                        (1.0_dp - a) * real(fb%pixels(k, x, y), dp) &
                        + a * lum)
                end do
            end do
        end do
    end subroutine apply_grayscale

    ! Sepia: blend toward the (255-clamped, unrounded) sepia matrix
    ! result with a = clamp(amount, 0, 1).  Matrix in the header.
    subroutine apply_sepia(fb, amount)
        type(FrameBuffer), intent(inout) :: fb
        real(dp), intent(in) :: amount

        integer :: x, y
        real(dp) :: a, r, g, b, target(3)

        a = min(1.0_dp, max(0.0_dp, amount))
        if (a <= 0.0_dp) return
        do y = 1, fb%height
            do x = 1, fb%width
                r = real(fb%pixels(1, x, y), dp)
                g = real(fb%pixels(2, x, y), dp)
                b = real(fb%pixels(3, x, y), dp)
                target(1) = min(255.0_dp, &
                    0.393_dp * r + 0.769_dp * g + 0.189_dp * b)
                target(2) = min(255.0_dp, &
                    0.349_dp * r + 0.686_dp * g + 0.168_dp * b)
                target(3) = min(255.0_dp, &
                    0.272_dp * r + 0.534_dp * g + 0.131_dp * b)
                fb%pixels(1, x, y) = clamp_round((1.0_dp - a) * r &
                                                 + a * target(1))
                fb%pixels(2, x, y) = clamp_round((1.0_dp - a) * g &
                                                 + a * target(2))
                fb%pixels(3, x, y) = clamp_round((1.0_dp - a) * b &
                                                 + a * target(3))
            end do
        end do
    end subroutine apply_sepia

end module postprocess_3d
