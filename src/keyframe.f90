! keyframe.f90 -- Full keyframe animation tracks (Wave B, B93).
!
! Extends v1's closed-form animation verbs (animation_3d) with
! explicit keyframe tracks: a pose (position, rotation in degrees,
! uniform scale) is sampled at arbitrary timeline seconds by
! interpolating between the surrounding keys, with the segment's
! easing taken from the key the segment ENDS at.
!
! Semantics (FROZEN; the JS (B95) and Python mirrors follow this
! EXACTLY):
!   * No keys allocated/empty -> pos 0, rot 0, scale 1.
!   * D = track%duration if > 0, else the last key's time;
!     if D <= 0 -> the first key's pose.
!   * Loop-map t to te:
!       once     -> clamp(t, 0, D)
!       forever  -> te = modulo(max(t, 0), D)   (exact multiples -> 0)
!       pingpong -> cyc = modulo(max(t, 0), 2D);
!                   te = cyc if cyc <= D, else 2D - cyc
!     Unknown loop modes behave as 'once'.
!   * If te <= keys(1)%time -> keys(1) pose.
!     If te >= keys(n)%time -> keys(n) pose.
!   * Else find the segment i with
!     keys(i)%time <= te <= keys(i+1)%time; local
!     p = (te - t_i) / (t_{i+1} - t_i) (zero-length segment -> p = 0);
!     e = ease_value(keys(i+1)%ease, p); pos/rot/scale are lerped
!     componentwise between keys(i) and keys(i+1) by e.
!   * Keys are assumed sorted by time (validation upstream
!     guarantees it); they are NOT sorted here.
!
! Easing is reused from animation_3d (ease_value); it is not
! reimplemented here.
module keyframe_3d
    use math_3d, only: dp
    use animation_3d, only: ease_value
    implicit none
    private
    public :: KeyFrame, KeyTrack, key_eval

    type :: KeyFrame
        real(dp) :: time = 0.0_dp
        real(dp) :: pos(3) = 0.0_dp
        real(dp) :: rot_deg(3) = 0.0_dp
        real(dp) :: scale = 1.0_dp
        character(len=16) :: ease = 'linear'   ! ease of the segment ENDING at this key
    end type KeyFrame

    type :: KeyTrack
        character(len=64) :: target = ''
        real(dp) :: duration = 0.0_dp          ! <=0 means: use last key's time
        character(len=16) :: loop = 'once'     ! once | forever | pingpong
        type(KeyFrame), allocatable :: keys(:)
    end type KeyTrack

contains

    subroutine key_eval(track, t, pos, rot_deg, scale)
        type(KeyTrack), intent(in) :: track
        real(dp), intent(in) :: t
        real(dp), intent(out) :: pos(3), rot_deg(3), scale

        integer :: n, i
        real(dp) :: d, te, cyc, p, e

        pos = 0.0_dp
        rot_deg = 0.0_dp
        scale = 1.0_dp

        if (.not. allocated(track%keys)) return
        n = size(track%keys)
        if (n == 0) return

        ! Effective duration.
        if (track%duration > 0.0_dp) then
            d = track%duration
        else
            d = track%keys(n)%time
        end if
        if (d <= 0.0_dp) then
            pos = track%keys(1)%pos
            rot_deg = track%keys(1)%rot_deg
            scale = track%keys(1)%scale
            return
        end if

        ! Loop-map t to te.
        select case (trim(track%loop))
        case ('forever')
            te = modulo(max(t, 0.0_dp), d)
        case ('pingpong')
            cyc = modulo(max(t, 0.0_dp), 2.0_dp * d)
            if (cyc <= d) then
                te = cyc
            else
                te = 2.0_dp * d - cyc
            end if
        case default  ! 'once' and anything unknown
            te = max(0.0_dp, min(t, d))
        end select

        ! Outside the keyed range: clamp to the end poses.
        if (te <= track%keys(1)%time) then
            pos = track%keys(1)%pos
            rot_deg = track%keys(1)%rot_deg
            scale = track%keys(1)%scale
            return
        end if
        if (te >= track%keys(n)%time) then
            pos = track%keys(n)%pos
            rot_deg = track%keys(n)%rot_deg
            scale = track%keys(n)%scale
            return
        end if

        ! Find the containing segment and interpolate.
        do i = 1, n - 1
            if (track%keys(i)%time <= te .and. te <= track%keys(i + 1)%time) then
                if (track%keys(i + 1)%time > track%keys(i)%time) then
                    p = (te - track%keys(i)%time) / &
                        (track%keys(i + 1)%time - track%keys(i)%time)
                else
                    p = 0.0_dp
                end if
                e = ease_value(track%keys(i + 1)%ease, p)
                pos = track%keys(i)%pos + &
                      (track%keys(i + 1)%pos - track%keys(i)%pos) * e
                rot_deg = track%keys(i)%rot_deg + &
                          (track%keys(i + 1)%rot_deg - track%keys(i)%rot_deg) * e
                scale = track%keys(i)%scale + &
                        (track%keys(i + 1)%scale - track%keys(i)%scale) * e
                return
            end if
        end do

        ! Unreachable for sorted keys given the clamps above; fall
        ! back to the last pose rather than leaving outputs unset.
        pos = track%keys(n)%pos
        rot_deg = track%keys(n)%rot_deg
        scale = track%keys(n)%scale
    end subroutine key_eval

end module keyframe_3d
