! post_v3.f90 -- Forge3D v3.0 Phase 3 colour/output pipeline
! (module post_v3_3d).
!
! This module operates on the v3 renderer's LINEAR real32 buffer
! (ADR-4) BEFORE quantisation -- unlike the legacy postprocess_3d
! chain, which runs on the already-quantised 8-bit framebuffer in
! main.  The interface is deliberately plain arrays (rgb, w, h)
! plus the Scene, so this module stays decoupled from
! renderer_v3_3d's buffer type: renderer_v3 passes its buffer
! components in, and v3_quantize_to_fb is the single call site.
!
! Pipeline order in post_v3_apply (all arithmetic real32, linear):
!   (i)   TRUE BLOOM, when the scene's post chain contains a
!         'bloom' entry (first match wins; amount = its
!         post_amounts entry):
!           * Bright-pass: per-pixel luminance
!             lum = 0.2126*R + 0.7152*G + 0.0722*B  (Rec.709, linear)
!             with threshold T = 1.0 in linear HDR and a soft knee
!             of half-width 0.25: the pass weight is the smoothstep
!             of lum over [T-0.25, T+0.25],
!               wgt = s*s*(3-2*s), s = clamp((lum-0.75)/0.5, 0, 1),
!             and bright = rgb * wgt.  HDR values > 1 pass through
!             at full weight -- that is the point of doing bloom on
!             the float buffer instead of the legacy 8-bit chain.
!           * Separable Gaussian blur of the bright-pass image:
!             radius R = clamp(nint(2*amount), 1, 16) pixels,
!             sigma = R/2, kernel g(i) = exp(-i^2/(2*sigma^2)) for
!             i in [-R, R], normalised to unit sum; one horizontal
!             pass then one vertical pass, edge indices clamped.
!             So amount 1 -> R=2/sigma=1, amount 2 -> R=4/sigma=2.
!           * Additive composite: rgb = rgb + amount * blurred.
!         amount <= 0 is an exact no-op.
!   (ii)  EXPOSURE + TONE MAPPING per channel, per
!         sc%tonemap_mode with xe = max(x,0) * exposure:
!           mode 1 (Reinhard):  y = xe / (1 + xe)
!           mode 2 (ACES):      Stephen Hill's ACES fitted curve
!             (the RRT+ODT fit from Hill's BakingLab reference,
!             applied per channel):
!               a = xe*(xe + 0.0245786) - 0.000090537
!               b = xe*(0.983729*xe + 0.4329510) + 0.238081
!               y = clamp(a/b, 0, 1)
!             Its asymptote is 1/0.983729 > 1, so highlights roll
!             off smoothly and reach 1 only asymptotically --
!             ACES(8) = 0.963, not a hard clip.
!           mode 0 / unknown:   y = xe  (exposure only, NO clamp;
!             clamping happens at byte encode).  'none' therefore
!             means 'no tone curve', not 'no output transform'.
!   (iii) sRGB ENCODE is NOT done here.  It is the output transform
!         applied once, at quantisation, by post_v3_linear_to_byte
!         (called from v3_quantize_to_fb):
!               c = clamp(x, 0, 1)
!               srgb = c*12.92                     if c <= 0.0031308
!                    = 1.055*c**(1/2.4) - 0.055    otherwise
!               byte = nint(srgb * 255), clamped to 0..255
!         (the standard IEC 61966-2-1 piecewise sRGB EOTF inverse).
!
! Determinism: this module uses NO OpenMP and no reductions whose
! order could vary; the blur passes are plain sequential loops in a
! fixed order and every other step is per-pixel.  The output is
! therefore identical for any FORGE3D_THREADS value.
module post_v3_3d
    use, intrinsic :: iso_fortran_env, only: real32
    use math_3d, only: dp
    use scene_3d, only: Scene
    implicit none
    private
    public :: post_v3_apply, post_v3_tonemap_value, post_v3_srgb, &
              post_v3_linear_to_byte

    ! Bloom bright-pass threshold in linear HDR (see header).
    real(real32), parameter :: BLOOM_THRESHOLD = 1.0_real32
    real(real32), parameter :: BLOOM_KNEE = 0.25_real32

contains

    ! ------------------------------------------------------------------
    ! Float stage: bloom (if requested by the scene post chain) then
    ! exposure + tone mapping, in place on rgb(3, w, h), real32 linear.
    ! ------------------------------------------------------------------
    subroutine post_v3_apply(rgb, w, h, sc)
        real(real32), intent(inout) :: rgb(3, w, h)
        integer, intent(in) :: w, h
        type(Scene), intent(in) :: sc
        integer :: i, x, y, k
        real(real32) :: amount, exposure

        ! (i) Bloom: first 'bloom' entry in the scene post chain.
        do i = 1, sc%n_post
            if (lower_name(sc%post_names(i)) == 'bloom') then
                amount = real(sc%post_amounts(i), real32)
                if (amount > 0.0_real32) call apply_bloom(rgb, w, h, amount)
                exit
            end if
        end do

        ! (ii) Exposure + tone mapping, per pixel / per channel.
        exposure = real(sc%tonemap_exposure, real32)
        do y = 1, h
            do x = 1, w
                do k = 1, 3
                    rgb(k, x, y) = post_v3_tonemap_value( &
                        sc%tonemap_mode, rgb(k, x, y), exposure)
                end do
            end do
        end do
    end subroutine post_v3_apply

    ! One linear scalar through exposure + the selected tone curve.
    ! Pure and public so tests can pin the float stage directly.
    pure function post_v3_tonemap_value(mode, x, exposure) result(y)
        integer, intent(in) :: mode
        real(real32), intent(in) :: x, exposure
        real(real32) :: y, xe, a, b
        xe = max(x * exposure, 0.0_real32)
        select case (mode)
        case (1)  ! Reinhard
            y = xe / (1.0_real32 + xe)
        case (2)  ! ACES, Stephen Hill fitted curve (see header)
            a = xe * (xe + 0.0245786_real32) - 0.000090537_real32
            b = xe * (0.983729_real32 * xe + 0.4329510_real32) &
                + 0.238081_real32
            y = min(max(a / b, 0.0_real32), 1.0_real32)
        case default  ! 0 / unknown: exposure only, no clamp
            y = xe
        end select
    end function post_v3_tonemap_value

    ! sRGB encode of one display-referred linear value in 0..1
    ! (input clamped first).  Pure; the ONLY encode in the v3 path.
    pure function post_v3_srgb(x) result(y)
        real(real32), intent(in) :: x
        real(real32) :: y, c
        c = min(max(x, 0.0_real32), 1.0_real32)
        if (c <= 0.0031308_real32) then
            y = c * 12.92_real32
        else
            y = 1.055_real32 * c ** (1.0_real32 / 2.4_real32) &
                - 0.055_real32
        end if
    end function post_v3_srgb

    ! Linear value -> output byte: sRGB encode, round to nearest,
    ! clamp to 0..255.  Used by v3_quantize_to_fb after the float
    ! stage; values > 1 (possible only with tonemap_mode 0) clamp.
    pure function post_v3_linear_to_byte(x) result(b)
        real(real32), intent(in) :: x
        integer :: b
        b = min(255, max(0, nint(post_v3_srgb(x) * 255.0_real32)))
    end function post_v3_linear_to_byte

    ! ------------------------------------------------------------------
    ! True bloom on the float buffer (see header for the exact math).
    ! Sequential fixed-order passes: deterministic by construction.
    ! ------------------------------------------------------------------
    subroutine apply_bloom(rgb, w, h, amount)
        real(real32), intent(inout) :: rgb(3, w, h)
        integer, intent(in) :: w, h
        real(real32), intent(in) :: amount
        real(real32), allocatable :: bright(:, :, :), tmp(:, :, :)
        real(real32) :: kern(-16:16), sigma, gsum, lum, s, wgt
        integer :: radius, i, x, y, k, d, xc, yc

        radius = min(16, max(1, nint(2.0_real32 * amount)))
        sigma = real(radius, real32) / 2.0_real32
        gsum = 0.0_real32
        do i = -radius, radius
            kern(i) = exp(-real(i * i, real32) / (2.0_real32 * sigma * sigma))
            gsum = gsum + kern(i)
        end do
        do i = -radius, radius
            kern(i) = kern(i) / gsum
        end do

        allocate(bright(3, w, h), tmp(3, w, h))
        ! Bright-pass with soft knee around the 1.0 HDR threshold.
        do y = 1, h
            do x = 1, w
                lum = 0.2126_real32 * rgb(1, x, y) &
                    + 0.7152_real32 * rgb(2, x, y) &
                    + 0.0722_real32 * rgb(3, x, y)
                s = min(max((lum - (BLOOM_THRESHOLD - BLOOM_KNEE)) &
                    / (2.0_real32 * BLOOM_KNEE), 0.0_real32), 1.0_real32)
                wgt = s * s * (3.0_real32 - 2.0_real32 * s)
                bright(:, x, y) = rgb(:, x, y) * wgt
            end do
        end do
        ! Horizontal pass: bright -> tmp.
        do y = 1, h
            do x = 1, w
                tmp(:, x, y) = 0.0_real32
                do d = -radius, radius
                    xc = min(w, max(1, x + d))
                    tmp(:, x, y) = tmp(:, x, y) + kern(d) * bright(:, xc, y)
                end do
            end do
        end do
        ! Vertical pass: tmp -> bright.
        do y = 1, h
            do x = 1, w
                bright(:, x, y) = 0.0_real32
                do d = -radius, radius
                    yc = min(h, max(1, y + d))
                    bright(:, x, y) = bright(:, x, y) &
                        + kern(d) * tmp(:, x, yc)
                end do
            end do
        end do
        ! Additive composite, scaled by the chain amount.
        do y = 1, h
            do x = 1, w
                do k = 1, 3
                    rgb(k, x, y) = rgb(k, x, y) + amount * bright(k, x, y)
                end do
            end do
        end do
        deallocate(bright, tmp)
    end subroutine apply_bloom

    ! Lower-case (ASCII A-Z only) copy of a post-chain name, for
    ! case-insensitive matching (same convention as postprocess_3d).
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

end module post_v3_3d
