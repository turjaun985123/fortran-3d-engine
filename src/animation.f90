! animation.f90 -- Closed-form, deterministic animation evaluation (P09 core).
!
! Every pose is a pure function f(t) of timeline seconds: no accumulated
! state, no frame-rate dependence (P09 section 3, principle 3).  This
! module does NOT build matrices; it returns the delta transform
! (added rotation in degrees, added position, uniform scale multiplier)
! that the caller composes onto an object's base transform.
module animation_3d
    use math_3d, only: dp, PI, deg2rad
    implicit none
    private
    public :: anim_eval, ease_value

    ! Fixed orbit radius (world units), P09 orbit primitive with the
    ! radius folded into a constant for the v1 API: see 'orbit' below.
    real(dp), parameter :: ORBIT_RADIUS = 2.0_dp
    real(dp), parameter :: BOB_AMPLITUDE = 0.5_dp
    real(dp), parameter :: PULSE_AMOUNT  = 0.2_dp

contains

    ! Easing on normalised progress p (expected in [0,1]; clamped here).
    ! Closed named set only (P09 section 5):
    !   'linear' -> p                 'smooth' -> p*p*(3-2p)
    !   'in'     -> p*p               'out'    -> 1-(1-p)^2
    ! Unknown names fall back to linear.
    pure function ease_value(name, p) result(e)
        character(*), intent(in) :: name
        real(dp), intent(in) :: p
        real(dp) :: e
        real(dp) :: u

        u = max(0.0_dp, min(1.0_dp, p))
        select case (trim(name))
        case ('smooth')
            e = u * u * (3.0_dp - 2.0_dp * u)
        case ('in')
            e = u * u
        case ('out')
            e = 1.0_dp - (1.0_dp - u) * (1.0_dp - u)
        case default  ! 'linear' and anything unknown
            e = u
        end select
    end function ease_value

    ! Map an axis name to a component index; 'y' is the default.
    pure function axis_index(axis) result(idx)
        character(*), intent(in) :: axis
        integer :: idx
        select case (trim(axis))
        case ('x')
            idx = 1
        case ('z')
            idx = 3
        case default  ! 'y' and anything unknown
            idx = 2
        end select
    end function axis_index

    ! Effective (loop-mapped) local time te for global time t:
    !   'once'     -> min(t, duration), clamped below at 0
    !   'forever'  -> modulo(t, duration) if duration > 0, else t
    !   'pingpong' -> triangle wave over 2*duration in [0, duration]
    ! Unknown loop modes behave as 'once'.  duration <= 0 gives te = 0
    ! (except 'forever', which passes t through as specified).
    pure function effective_time(t, duration, loop_mode) result(te)
        real(dp), intent(in) :: t, duration
        character(*), intent(in) :: loop_mode
        real(dp) :: te
        real(dp) :: cyc

        select case (trim(loop_mode))
        case ('forever')
            if (duration > 0.0_dp) then
                te = modulo(t, duration)
            else
                te = t
            end if
        case ('pingpong')
            if (duration > 0.0_dp) then
                cyc = modulo(t, 2.0_dp * duration)
                if (cyc <= duration) then
                    te = cyc
                else
                    te = 2.0_dp * duration - cyc
                end if
            else
                te = 0.0_dp
            end if
        case default  ! 'once' and anything unknown
            if (duration > 0.0_dp) then
                te = max(0.0_dp, min(t, duration))
            else
                te = 0.0_dp
            end if
        end select
    end function effective_time

    ! Evaluate one animation primitive at time t (seconds).
    !
    !   kind       'spin','bob','pulse','orbit','move','turn','grow'
    !   axis       'x','y','z' (channel axis for spin/turn/move)
    !   speed      deg/s for spin/turn/orbit, units/s factor for move
    !   duration   clip duration / period in seconds
    !   loop_mode  'forever','once','pingpong'
    !   ease       'linear','smooth','in','out'
    ! Outputs (always fully set; unknown kind -> zeros and scale 1):
    !   d_rot_deg(3)  added rotation, degrees, per axis component
    !   d_pos(3)      added position
    !   scale_factor  uniform scale multiplier (1 = no change)
    !
    ! Semantics per kind (p = te/duration raw, ep = ease_value(ease,p)):
    !   spin/turn  angle = speed*duration*ep on the axis component.
    !              Special case: spin with loop 'forever' and ease
    !              'linear' is continuous and unbounded, angle =
    !              speed*t, so a forever spin wraps seamlessly at any
    !              frame (e.g. frame 150) instead of restarting.
    !   bob        d_pos(2) = 0.5*sin(2*pi*p)  (raw p; periodic, P09 S5)
    !   pulse      scale_factor = 1 + 0.2*sin(2*pi*p)  (raw p)
    !   grow       scale_factor = max(ep, 0.01), growing 0 -> 1 over
    !              duration with 'once' semantics regardless of
    !              loop_mode (it does not shrink back / re-grow).
    !   orbit      position only (no facing rotation is added):
    !              a = deg2rad(speed*te) about Y, radius R = 2.0 fixed,
    !              d_pos = ((cos(a)-1)*R, 0, sin(a)*R), so the delta
    !              is zero at t = 0 (object starts at its base pose).
    !   move       d_pos(axis) = speed*duration*ep
    subroutine anim_eval(kind, t, speed, duration, axis, loop_mode, ease, &
                         d_rot_deg, d_pos, scale_factor)
        character(*), intent(in) :: kind, axis, loop_mode, ease
        real(dp), intent(in) :: t, speed, duration
        real(dp), intent(out) :: d_rot_deg(3), d_pos(3), scale_factor

        real(dp) :: te, p, ep, angle_deg, a_rad, te_once, p_once
        integer :: idx

        d_rot_deg = 0.0_dp
        d_pos = 0.0_dp
        scale_factor = 1.0_dp

        te = effective_time(t, duration, loop_mode)
        if (duration > 0.0_dp) then
            p = max(0.0_dp, min(1.0_dp, te / duration))
        else
            p = 0.0_dp
        end if
        ep = ease_value(ease, p)
        idx = axis_index(axis)

        select case (trim(kind))
        case ('spin')
            if (trim(loop_mode) == 'forever' .and. trim(ease) == 'linear') then
                angle_deg = speed * t
            else
                angle_deg = speed * duration * ep
            end if
            d_rot_deg(idx) = angle_deg
        case ('turn')
            d_rot_deg(idx) = speed * duration * ep
        case ('bob')
            d_pos(2) = BOB_AMPLITUDE * sin(2.0_dp * PI * p)
        case ('pulse')
            scale_factor = 1.0_dp + PULSE_AMOUNT * sin(2.0_dp * PI * p)
        case ('grow')
            te_once = effective_time(t, duration, 'once')
            if (duration > 0.0_dp) then
                p_once = max(0.0_dp, min(1.0_dp, te_once / duration))
            else
                p_once = 0.0_dp
            end if
            scale_factor = max(ease_value(ease, p_once), 0.01_dp)
        case ('orbit')
            a_rad = deg2rad(speed * te)
            d_pos(1) = (cos(a_rad) - 1.0_dp) * ORBIT_RADIUS
            d_pos(2) = 0.0_dp
            d_pos(3) = sin(a_rad) * ORBIT_RADIUS
        case ('move')
            d_pos(idx) = speed * duration * ep
        case default
            ! Unknown kind: zero outputs and scale 1 (set above).
        end select
    end subroutine anim_eval

end module animation_3d
