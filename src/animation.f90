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
    !
    ! v3.0 Phase 5 (additive; the names above are unchanged):
    !   'cubic-in'     -> p^3
    !   'cubic-out'    -> 1-(1-p)^3
    !   'cubic-in-out' -> 4p^3 for p < 0.5, else 1-(-2p+2)^3/2
    !   'bezier(x1,y1,x2,y2)' -> cubic Bezier easing with control
    !       points (0,0), (x1,y1), (x2,y2), (1,1): solve x(t) = p
    !       for t (Newton with a bisection fallback), return y(t).
    !       x1/x2 are clamped to [0,1]; a malformed bezier string
    !       falls back to linear, like any unknown name.
    pure function ease_value(name, p) result(e)
        character(*), intent(in) :: name
        real(dp), intent(in) :: p
        real(dp) :: e
        real(dp) :: u
        character(len=64) :: nm
        real(dp) :: bx1, by1, bx2, by2
        logical :: bez_ok

        u = max(0.0_dp, min(1.0_dp, p))
        nm = trim(name)
        if (len_trim(nm) >= 7 .and. nm(1:7) == 'bezier(') then
            call parse_bezier_args(nm, bx1, by1, bx2, by2, bez_ok)
            if (bez_ok) then
                e = bezier_ease(bx1, by1, bx2, by2, u)
            else
                e = u  ! malformed -> linear
            end if
            return
        end if
        select case (trim(nm))
        case ('smooth')
            e = u * u * (3.0_dp - 2.0_dp * u)
        case ('in')
            e = u * u
        case ('out')
            e = 1.0_dp - (1.0_dp - u) * (1.0_dp - u)
        case ('cubic-in')
            e = u * u * u
        case ('cubic-out')
            e = 1.0_dp - (1.0_dp - u) * (1.0_dp - u) * (1.0_dp - u)
        case ('cubic-in-out')
            if (u < 0.5_dp) then
                e = 4.0_dp * u * u * u
            else
                e = 1.0_dp - ((-2.0_dp * u + 2.0_dp) ** 3) / 2.0_dp
            end if
        case default  ! 'linear' and anything unknown
            e = u
        end select
    end function ease_value

    ! Parse the argument list of 'bezier(x1,y1,x2,y2)' (s is the
    ! already-trimmed ease name, known to start with 'bezier(').
    ! ok=.false. on any malformation: missing ')', wrong argument
    ! count, or a non-numeric argument.  Control x values are
    ! clamped to [0,1] here; y values are unrestricted.
    pure subroutine parse_bezier_args(s, x1, y1, x2, y2, ok)
        character(*), intent(in) :: s
        real(dp), intent(out) :: x1, y1, x2, y2
        logical, intent(out) :: ok
        integer :: i, n, ncomma, close_pos
        real(dp) :: vals(4)
        integer :: start, idx
        logical :: num_ok

        ok = .false.
        x1 = 0.0_dp; y1 = 0.0_dp; x2 = 0.0_dp; y2 = 0.0_dp
        n = len_trim(s)
        close_pos = 0
        ncomma = 0
        do i = 1, n
            if (s(i:i) == ')') close_pos = i
            if (s(i:i) == ',') ncomma = ncomma + 1
        end do
        if (close_pos /= n .or. ncomma /= 3) return
        ! Split s(8:close_pos-1) on commas into exactly 4 numbers.
        start = 8
        idx = 0
        do i = 8, close_pos
            if (i == close_pos .or. s(i:i) == ',') then
                idx = idx + 1
                if (idx > 4) return
                call parse_decimal(s(start:i - 1), vals(idx), num_ok)
                if (.not. num_ok) return
                start = i + 1
            end if
        end do
        if (idx /= 4) return
        x1 = max(0.0_dp, min(1.0_dp, vals(1)))
        y1 = vals(2)
        x2 = max(0.0_dp, min(1.0_dp, vals(3)))
        y2 = vals(4)
        ok = .true.
    end subroutine parse_bezier_args

    ! Strict decimal parser (no I/O, so ease_value stays pure):
    ! [+-] digits [. digits] [(e|E) [+-] digits]; at least one digit
    ! in the mantissa.  Surrounding spaces are allowed.
    pure subroutine parse_decimal(s, x, ok)
        character(*), intent(in) :: s
        real(dp), intent(out) :: x
        logical, intent(out) :: ok
        integer :: n
        ! Work on a blank-padded copy: Fortran does not guarantee
        ! short-circuit .and., so s(i:i) must never be evaluated
        ! with i > len(s); the 512-char buffer makes every access
        ! in parse_decimal_buf in-bounds (positions past the text
        ! read as blanks).
        character(len=512) :: buf

        ok = .false.
        x = 0.0_dp
        if (len(s) > 500) return
        buf = s
        n = len_trim(buf)
        call parse_decimal_buf(buf, n, x, ok)
    end subroutine parse_decimal

    pure subroutine parse_decimal_buf(s, n, x, ok)
        character(*), intent(in) :: s
        integer, intent(in) :: n
        real(dp), intent(out) :: x
        logical, intent(out) :: ok
        integer :: i, ndig
        real(dp) :: mant, frac, expo, sign
        logical :: seen_dot, seen_exp, exp_neg

        ok = .false.
        x = 0.0_dp
        i = 1
        do while (i <= n .and. s(i:i) == ' ')
            i = i + 1
        end do
        sign = 1.0_dp
        if (i <= n .and. (s(i:i) == '-' .or. s(i:i) == '+')) then
            if (s(i:i) == '-') sign = -1.0_dp
            i = i + 1
        end if
        mant = 0.0_dp
        frac = 0.1_dp
        ndig = 0
        seen_dot = .false.
        do while (i <= n)
            if (s(i:i) >= '0' .and. s(i:i) <= '9') then
                ndig = ndig + 1
                if (seen_dot) then
                    mant = mant + real(iachar(s(i:i)) - iachar('0'), dp) * frac
                    frac = frac * 0.1_dp
                else
                    mant = mant * 10.0_dp + &
                           real(iachar(s(i:i)) - iachar('0'), dp)
                end if
                i = i + 1
            else if (s(i:i) == '.' .and. .not. seen_dot) then
                seen_dot = .true.
                i = i + 1
            else
                exit
            end if
        end do
        if (ndig == 0) return
        expo = 0.0_dp
        seen_exp = .false.
        exp_neg = .false.
        if (i <= n .and. (s(i:i) == 'e' .or. s(i:i) == 'E')) then
            seen_exp = .true.
            i = i + 1
            if (i <= n .and. (s(i:i) == '-' .or. s(i:i) == '+')) then
                exp_neg = (s(i:i) == '-')
                i = i + 1
            end if
            if (i > n) return
            if (s(i:i) < '0' .or. s(i:i) > '9') return
            do while (i <= n .and. s(i:i) >= '0' .and. s(i:i) <= '9')
                expo = expo * 10.0_dp + &
                       real(iachar(s(i:i)) - iachar('0'), dp)
                i = i + 1
            end do
        end if
        do while (i <= n .and. s(i:i) == ' ')
            i = i + 1
        end do
        if (i <= n) return
        if (seen_exp) then
            if (exp_neg) expo = -expo
            mant = mant * (10.0_dp ** expo)
        end if
        x = sign * mant
        ok = .true.
    end subroutine parse_decimal_buf

    ! One coordinate of the cubic Bezier with endpoints 0 and 1 and
    ! control values c1, c2, at parameter t.
    pure function bezier_coord(c1, c2, t) result(v)
        real(dp), intent(in) :: c1, c2, t
        real(dp) :: v
        real(dp) :: mt
        mt = 1.0_dp - t
        v = 3.0_dp * mt * mt * t * c1 + 3.0_dp * mt * t * t * c2 + t * t * t
    end function bezier_coord

    ! Derivative of bezier_coord with respect to t.
    pure function bezier_coord_dt(c1, c2, t) result(v)
        real(dp), intent(in) :: c1, c2, t
        real(dp) :: v
        real(dp) :: mt
        mt = 1.0_dp - t
        v = 3.0_dp * mt * mt * c1 + 6.0_dp * mt * t * (c2 - c1) + &
            3.0_dp * t * t * (1.0_dp - c2)
    end function bezier_coord_dt

    ! Cubic-bezier easing: solve x(t) = p for t, return y(t).
    ! Newton from t = p; if it stalls or leaves [0,1], fall back to
    ! bisection (x(t) is monotonic for control x in [0,1]).
    pure function bezier_ease(x1, y1, x2, y2, p) result(e)
        real(dp), intent(in) :: x1, y1, x2, y2, p
        real(dp) :: e
        real(dp) :: t, err, der, lo, hi
        integer :: i

        if (p <= 0.0_dp) then
            e = 0.0_dp
            return
        end if
        if (p >= 1.0_dp) then
            e = 1.0_dp
            return
        end if
        t = p
        do i = 1, 8
            err = bezier_coord(x1, x2, t) - p
            if (abs(err) < 1.0e-12_dp) exit
            der = bezier_coord_dt(x1, x2, t)
            if (abs(der) < 1.0e-9_dp) exit
            t = t - err / der
            if (t < 0.0_dp .or. t > 1.0_dp) exit
        end do
        if (t < 0.0_dp .or. t > 1.0_dp .or. &
            abs(bezier_coord(x1, x2, t) - p) >= 1.0e-9_dp) then
            lo = 0.0_dp
            hi = 1.0_dp
            t = p
            do i = 1, 40
                err = bezier_coord(x1, x2, t) - p
                if (abs(err) < 1.0e-12_dp) exit
                if (err > 0.0_dp) then
                    hi = t
                else
                    lo = t
                end if
                t = 0.5_dp * (lo + hi)
            end do
        end if
        e = bezier_coord(y1, y2, t)
    end function bezier_ease

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
