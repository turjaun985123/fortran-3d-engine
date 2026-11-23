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
!
! v3.0 Phase 5 (additive; the FROZEN semantics above are unchanged
! for tracks that do not use the new fields):
!   * KeyFrame%rot_quat / %has_quat: rotation is AUTHORED as Euler
!     (rot_deg, the file/storage form) and STORED for runtime
!     interpolation as a quaternion.  Scene loading fills rot_quat
!     = quat_from_euler(rot_deg) and sets has_quat.  key_eval_q
!     interpolates with quat_slerp (shortest path), which fixes
!     the M2 defects of Euler lerp: gimbal-lock degeneracy and
!     the 350 -> 10 degree wrap going the long way (through 180).
!   * KeyFrame%scale3 / %has_scale3: per-axis scale; when a key
!     has_scale3, key_eval_q lerps scale3 componentwise, otherwise
!     the uniform scale is broadcast to all three axes.
!   * KeyTrack%fps (M3): when > 0, the track's key times and
!     duration are FRAME NUMBERS, not seconds.  Both evaluators
!     take t in seconds and convert internally (t_frames =
!     t * fps; equivalently every key time/duration in seconds is
!     time / fps), so loop mapping, easing and interpolation all
!     run in the frame coordinate exactly as the legacy code runs
!     in seconds when fps == 0.  fps == 0 is the legacy behaviour,
!     bit-identical.
!   * key_eval itself is untouched apart from the fps time
!     conversion: its Euler-lerp outputs for existing tracks are
!     byte-identical to the frozen semantics.
module keyframe_3d
    use math_3d, only: dp, quat, quat_from_euler, quat_identity, &
        quat_slerp, vec3_create
    use animation_3d, only: ease_value
    implicit none
    private
    public :: KeyFrame, KeyTrack, key_eval, key_eval_q

    type :: KeyFrame
        real(dp) :: time = 0.0_dp
        real(dp) :: pos(3) = 0.0_dp
        real(dp) :: rot_deg(3) = 0.0_dp
        real(dp) :: scale = 1.0_dp
        character(len=16) :: ease = 'linear'   ! ease of the segment ENDING at this key
        ! Phase 5 (additive): quaternion form of rot_deg (runtime
        ! interpolation form).  Default is the identity rotation
        ! (the quat type's own component defaults); has_quat gates
        ! its use so hand-built keys that never set it fall back
        ! to converting rot_deg.
        type(quat) :: rot_quat
        logical :: has_quat = .false.
        ! Phase 5 (additive): per-axis scale; used by key_eval_q
        ! only when has_scale3.
        real(dp) :: scale3(3) = 1.0_dp
        logical :: has_scale3 = .false.
    end type KeyFrame

    type :: KeyTrack
        character(len=64) :: target = ''
        real(dp) :: duration = 0.0_dp          ! <=0 means: use last key's time
        character(len=16) :: loop = 'once'     ! once | forever | pingpong
        type(KeyFrame), allocatable :: keys(:)
        ! Phase 5 (M3, additive): >0 means key times/duration are
        ! frame numbers at this rate; 0 = legacy seconds.
        real(dp) :: fps = 0.0_dp
    end type KeyTrack

contains

    ! The rotation of one key as a quaternion: the stored
    ! rot_quat when has_quat, else rot_deg converted on the spot
    ! (the two agree wherever the authoring conversion ran).
    pure function key_quat(kf) result(q)
        type(KeyFrame), intent(in) :: kf
        type(quat) :: q
        if (kf%has_quat) then
            q = kf%rot_quat
        else
            q = quat_from_euler(vec3_create(kf%rot_deg(1), &
                kf%rot_deg(2), kf%rot_deg(3)))
        end if
    end function key_quat

    ! The per-axis scale of one key: scale3 when has_scale3, else
    ! the uniform scale broadcast to all axes.
    pure function key_scale3(kf) result(s)
        type(KeyFrame), intent(in) :: kf
        real(dp) :: s(3)
        if (kf%has_scale3) then
            s = kf%scale3
        else
            s = kf%scale
        end if
    end function key_scale3

    ! Full pose of one key in key_eval_q's output form.
    pure subroutine key_pose_q(kf, pos, q, s3)
        type(KeyFrame), intent(in) :: kf
        real(dp), intent(out) :: pos(3), s3(3)
        type(quat), intent(out) :: q
        pos = kf%pos
        q = key_quat(kf)
        s3 = key_scale3(kf)
    end subroutine key_pose_q

    subroutine key_eval(track, t, pos, rot_deg, scale)
        type(KeyTrack), intent(in) :: track
        real(dp), intent(in) :: t
        real(dp), intent(out) :: pos(3), rot_deg(3), scale

        integer :: n, i
        real(dp) :: d, te, cyc, p, e, tt

        pos = 0.0_dp
        rot_deg = 0.0_dp
        scale = 1.0_dp

        if (.not. allocated(track%keys)) return
        n = size(track%keys)
        if (n == 0) return

        ! Phase 5 (M3): with fps > 0 the key times/duration are
        ! frame numbers; convert the seconds input into the frame
        ! coordinate once, here.  fps == 0: tt = t, bit-identical.
        if (track%fps > 0.0_dp) then
            tt = t * track%fps
        else
            tt = t
        end if

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
            te = modulo(max(tt, 0.0_dp), d)
        case ('pingpong')
            cyc = modulo(max(tt, 0.0_dp), 2.0_dp * d)
            if (cyc <= d) then
                te = cyc
            else
                te = 2.0_dp * d - cyc
            end if
        case default  ! 'once' and anything unknown
            te = max(0.0_dp, min(tt, d))
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

    ! Phase 5 evaluator: same loop-map / segment / easing skeleton
    ! as key_eval (including the fps time conversion), but the
    ! rotation is interpolated with quat_slerp between the keys'
    ! quaternion forms (shortest path; see the module header) and
    ! the scale is per-axis.  For a track whose keys carry neither
    ! has_quat nor has_scale3 and whose fps is 0, the pos output
    ! equals key_eval's and the rotation/scale are the same pose
    ! expressed in the new forms.
    subroutine key_eval_q(track, t, pos, quat_out, scale3_out)
        type(KeyTrack), intent(in) :: track
        real(dp), intent(in) :: t
        real(dp), intent(out) :: pos(3), scale3_out(3)
        type(quat), intent(out) :: quat_out

        integer :: n, i
        real(dp) :: d, te, cyc, p, e, tt
        real(dp) :: s1(3), s2(3)
        type(quat) :: q1, q2

        pos = 0.0_dp
        quat_out = quat_identity()
        scale3_out = 1.0_dp

        if (.not. allocated(track%keys)) return
        n = size(track%keys)
        if (n == 0) return

        if (track%fps > 0.0_dp) then
            tt = t * track%fps
        else
            tt = t
        end if

        if (track%duration > 0.0_dp) then
            d = track%duration
        else
            d = track%keys(n)%time
        end if
        if (d <= 0.0_dp) then
            call key_pose_q(track%keys(1), pos, quat_out, scale3_out)
            return
        end if

        select case (trim(track%loop))
        case ('forever')
            te = modulo(max(tt, 0.0_dp), d)
        case ('pingpong')
            cyc = modulo(max(tt, 0.0_dp), 2.0_dp * d)
            if (cyc <= d) then
                te = cyc
            else
                te = 2.0_dp * d - cyc
            end if
        case default  ! 'once' and anything unknown
            te = max(0.0_dp, min(tt, d))
        end select

        if (te <= track%keys(1)%time) then
            call key_pose_q(track%keys(1), pos, quat_out, scale3_out)
            return
        end if
        if (te >= track%keys(n)%time) then
            call key_pose_q(track%keys(n), pos, quat_out, scale3_out)
            return
        end if

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
                q1 = key_quat(track%keys(i))
                q2 = key_quat(track%keys(i + 1))
                quat_out = quat_slerp(q1, q2, e)
                s1 = key_scale3(track%keys(i))
                s2 = key_scale3(track%keys(i + 1))
                scale3_out = s1 + (s2 - s1) * e
                return
            end if
        end do

        call key_pose_q(track%keys(n), pos, quat_out, scale3_out)
    end subroutine key_eval_q

end module keyframe_3d
