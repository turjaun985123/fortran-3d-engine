! char_figure.f90 -- procedural stickman figure (ANIM-PLAN section 4.2/4.3,
! Wave 3 Slice S2).
!
! A character is NOT modelled geometry: it is a pose (one value per rig
! channel) + a proportions record + an identity record, turned into real
! geometry per frame by this module (Approach A: jointed figure as real
! geometry in a camera-facing plane, yaw-billboarded about world Y).
!
! SHARED SPEC (compiler + JS slices implement to the same contract):
!   Channels (pose = one value per channel, in this order):
!     root.x, root.y, root.z, root.face (deg), torso (deg),
!     head.pitch, head.yaw (deg),
!     arm.l.upper, arm.l.fore, arm.r.upper, arm.r.fore,
!     leg.l.thigh, leg.l.shin, leg.r.thigh, leg.r.shin (all deg),
!     face.expr (0 neutral, 1 happy, 2 sad, 3 determined, 4 surprised).
!   Rest pose = all angles 0, face.expr = declared face.
!   Proportions (adult base, world units): thigh 0.45, shin 0.45,
!     torso 0.55, upper_arm 0.30, fore_arm 0.28, head_r 0.16,
!     line_r 0.035, shoulder_half 0.19, hip_half 0.11, neck 0.06.
!     Total height H0 = thigh+shin+torso+neck+2*head_r = 1.83.
!   FK in the figure plane (u = right, v = up), root ground point =
!   local origin; world placement billboards the plane to the camera
!   and then rotates it by root.face degrees about Y.
!
! Everything here is a pure function of the pose (no accumulated
! state), matching the engine's house principle for animation.
module char_figure_3d
    use math_3d
    use mesh_3d
    use mesh_data_3d
    use geo_capsule_3d, only: build_capsule_data
    use material_3d, only: material_id_from_name
    implicit none
    private

    public :: figure_props, figure_identity, figure_wear, figure_pose
    public :: props_from_spec, figure_total_height
    public :: pose_rest, figure_channel_name, figure_joint_name
    public :: figure_fk, figure_facing_basis, figure_joints_world
    public :: figure_build_mesh

    ! ---- rig channels (spec order; index into figure_pose%ch) ----
    integer, parameter, public :: CH_ROOT_X = 1
    integer, parameter, public :: CH_ROOT_Y = 2
    integer, parameter, public :: CH_ROOT_Z = 3
    integer, parameter, public :: CH_ROOT_FACE = 4
    integer, parameter, public :: CH_TORSO = 5
    integer, parameter, public :: CH_HEAD_PITCH = 6
    integer, parameter, public :: CH_HEAD_YAW = 7
    integer, parameter, public :: CH_ARM_L_UPPER = 8
    integer, parameter, public :: CH_ARM_L_FORE = 9
    integer, parameter, public :: CH_ARM_R_UPPER = 10
    integer, parameter, public :: CH_ARM_R_FORE = 11
    integer, parameter, public :: CH_LEG_L_THIGH = 12
    integer, parameter, public :: CH_LEG_L_SHIN = 13
    integer, parameter, public :: CH_LEG_R_THIGH = 14
    integer, parameter, public :: CH_LEG_R_SHIN = 15
    integer, parameter, public :: CH_FACE_EXPR = 16
    integer, parameter, public :: N_CHANNELS = 16

    ! ---- face.expr values ----
    integer, parameter, public :: EXPR_NEUTRAL = 0
    integer, parameter, public :: EXPR_HAPPY = 1
    integer, parameter, public :: EXPR_SAD = 2
    integer, parameter, public :: EXPR_DETERMINED = 3
    integer, parameter, public :: EXPR_SURPRISED = 4

    ! ---- joints ----
    ! NOTE: the spec text says "15 joints" but enumerates 16 names
    ! (the ANIM-PLAN 4.2 list of 15 has no neck/hipC; the shared spec
    ! adds both).  All 16 enumerated joints are exposed here.
    integer, parameter, public :: J_ROOT = 1
    integer, parameter, public :: J_HEAD = 2
    integer, parameter, public :: J_NECK = 3
    integer, parameter, public :: J_SHOULDER_L = 4
    integer, parameter, public :: J_SHOULDER_R = 5
    integer, parameter, public :: J_ELBOW_L = 6
    integer, parameter, public :: J_ELBOW_R = 7
    integer, parameter, public :: J_HAND_L = 8
    integer, parameter, public :: J_HAND_R = 9
    integer, parameter, public :: J_HIP_C = 10
    integer, parameter, public :: J_HIP_L = 11
    integer, parameter, public :: J_HIP_R = 12
    integer, parameter, public :: J_KNEE_L = 13
    integer, parameter, public :: J_KNEE_R = 14
    integer, parameter, public :: J_FOOT_L = 15
    integer, parameter, public :: J_FOOT_R = 16
    integer, parameter, public :: N_JOINTS = 16

    integer, parameter, public :: FIG_MAX_WEARS = 4
    integer, parameter :: FIG_NAME_LEN = 32
    integer, parameter :: FIG_HOLD_LEN = 64

    ! Proportions record: segment lengths etc. (world units) + the
    ! character's own colour (the mesh builder also takes base_color
    ! explicitly; props%color is the identity-side copy).
    type :: figure_props
        real(dp) :: thigh = 0.45_dp
        real(dp) :: shin = 0.45_dp
        real(dp) :: torso = 0.55_dp
        real(dp) :: upper_arm = 0.30_dp
        real(dp) :: fore_arm = 0.28_dp
        real(dp) :: head_r = 0.16_dp
        real(dp) :: line_r = 0.035_dp
        real(dp) :: shoulder_half = 0.19_dp
        real(dp) :: hip_half = 0.11_dp
        real(dp) :: neck = 0.06_dp
        integer :: color(3) = [255, 255, 255]
    end type figure_props

    type :: figure_wear
        character(len=FIG_NAME_LEN) :: item = ''
        integer :: color(3) = [255, 255, 255]
    end type figure_wear

    ! Identity: who the character IS (proportions/head/wears/holds).
    ! Cues may change face/position/pose only, never this record.
    type :: figure_identity
        character(len=FIG_NAME_LEN) :: head_style = 'round'  ! round|square|oval
        character(len=FIG_NAME_LEN) :: hair = ''             ! '' | bun | <word>
        integer :: hair_color(3) = [40, 30, 22]
        integer :: n_wears = 0
        type(figure_wear) :: wears(FIG_MAX_WEARS)
        character(len=FIG_HOLD_LEN) :: holds = ''
    end type figure_identity

    ! Pose: one value per rig channel, indexed by the CH_* enum.
    type :: figure_pose
        real(dp) :: ch(N_CHANNELS) = 0.0_dp
    end type figure_pose

    ! Adult total height H0 (spec constant).
    real(dp), parameter, public :: FIGURE_H0 = 1.83_dp

contains

    pure function figure_total_height(props) result(h)
        type(figure_props), intent(in) :: props
        real(dp) :: h
        h = props%thigh + props%shin + props%torso + props%neck &
            + 2.0_dp * props%head_r
    end function figure_total_height

    ! Build a proportions record from a proportions word
    ! (''/adult | tall | short | kid) plus an optional exact height.
    !   tall  -> lengths x1.12, head_r x1.05
    !   short -> lengths x0.88, head_r x1.0
    !   kid   -> lengths x0.62, head_r x0.806 (bigger head, relatively)
    ! "lengths" = thigh, shin, torso, upper_arm, fore_arm, neck,
    ! shoulder_half, hip_half (line_r is a stroke weight, not a length,
    ! and is left alone by the word modifiers).
    !   height n -> uniform scale n / (current total height) applied
    !   to EVERY field (lengths, head_r, line_r, halves), so the
    !   resulting figure_total_height is exactly n.
    pure function props_from_spec(proportions_word, height, has_height, &
                                  color) result(p)
        character(len=*), intent(in) :: proportions_word
        real(dp), intent(in) :: height
        logical, intent(in) :: has_height
        integer, intent(in), optional :: color(3)
        type(figure_props) :: p
        real(dp) :: f, fh, s

        p = figure_props()
        if (present(color)) p%color = color

        f = 1.0_dp
        fh = 1.0_dp
        select case (trim(proportions_word))
        case ('tall')
            f = 1.12_dp
            fh = 1.05_dp
        case ('short')
            f = 0.88_dp
            fh = 1.0_dp
        case ('kid')
            f = 0.62_dp
            fh = 0.806_dp
        case default
            f = 1.0_dp
            fh = 1.0_dp
        end select
        p%thigh = p%thigh * f
        p%shin = p%shin * f
        p%torso = p%torso * f
        p%upper_arm = p%upper_arm * f
        p%fore_arm = p%fore_arm * f
        p%neck = p%neck * f
        p%shoulder_half = p%shoulder_half * f
        p%hip_half = p%hip_half * f
        p%head_r = p%head_r * fh

        if (has_height) then
            s = height / figure_total_height(p)
            p%thigh = p%thigh * s
            p%shin = p%shin * s
            p%torso = p%torso * s
            p%upper_arm = p%upper_arm * s
            p%fore_arm = p%fore_arm * s
            p%neck = p%neck * s
            p%shoulder_half = p%shoulder_half * s
            p%hip_half = p%hip_half * s
            p%head_r = p%head_r * s
            p%line_r = p%line_r * s
        end if
    end function props_from_spec

    ! Rest pose: all angles 0, face.expr = the declared face.
    pure function pose_rest(face_expr) result(p)
        real(dp), intent(in) :: face_expr
        type(figure_pose) :: p
        p%ch = 0.0_dp
        p%ch(CH_FACE_EXPR) = face_expr
    end function pose_rest

    pure function figure_channel_name(idx) result(name)
        integer, intent(in) :: idx
        character(len=16) :: name
        select case (idx)
        case (CH_ROOT_X);      name = 'root.x'
        case (CH_ROOT_Y);      name = 'root.y'
        case (CH_ROOT_Z);      name = 'root.z'
        case (CH_ROOT_FACE);   name = 'root.face'
        case (CH_TORSO);       name = 'torso'
        case (CH_HEAD_PITCH);  name = 'head.pitch'
        case (CH_HEAD_YAW);    name = 'head.yaw'
        case (CH_ARM_L_UPPER); name = 'arm.l.upper'
        case (CH_ARM_L_FORE);  name = 'arm.l.fore'
        case (CH_ARM_R_UPPER); name = 'arm.r.upper'
        case (CH_ARM_R_FORE);  name = 'arm.r.fore'
        case (CH_LEG_L_THIGH); name = 'leg.l.thigh'
        case (CH_LEG_L_SHIN);  name = 'leg.l.shin'
        case (CH_LEG_R_THIGH); name = 'leg.r.thigh'
        case (CH_LEG_R_SHIN);  name = 'leg.r.shin'
        case (CH_FACE_EXPR);   name = 'face.expr'
        case default;          name = ''
        end select
    end function figure_channel_name

    pure function figure_joint_name(idx) result(name)
        integer, intent(in) :: idx
        character(len=16) :: name
        select case (idx)
        case (J_ROOT);       name = 'root'
        case (J_HEAD);       name = 'head'
        case (J_NECK);       name = 'neck'
        case (J_SHOULDER_L); name = 'shoulder.L'
        case (J_SHOULDER_R); name = 'shoulder.R'
        case (J_ELBOW_L);    name = 'elbow.L'
        case (J_ELBOW_R);    name = 'elbow.R'
        case (J_HAND_L);     name = 'hand.L'
        case (J_HAND_R);     name = 'hand.R'
        case (J_HIP_C);      name = 'hipC'
        case (J_HIP_L);      name = 'hip.L'
        case (J_HIP_R);      name = 'hip.R'
        case (J_KNEE_L);     name = 'knee.L'
        case (J_KNEE_R);     name = 'knee.R'
        case (J_FOOT_L);     name = 'foot.L'
        case (J_FOOT_R);     name = 'foot.R'
        case default;        name = ''
        end select
    end function figure_joint_name

    ! Limb direction for an angle in degrees, measured from straight
    ! down, positive toward +u: d(t) = (sin t, -cos t).
    pure function limb_dir(deg) result(d)
        real(dp), intent(in) :: deg
        real(dp) :: d(2), r
        r = deg2rad(deg)
        d = [sin(r), -cos(r)]
    end function limb_dir

    ! Forward kinematics in the figure plane.
    ! Returns uv(1:2, joint): uv(1) = u (right), uv(2) = v (up).
    ! Pure; head.pitch / head.yaw / root.* do not move joint centres
    ! (pitch/yaw steer the face features at mesh-build time; root.*
    ! place the figure in the world -- see figure_joints_world).
    pure function figure_fk(pose, props) result(uv)
        type(figure_pose), intent(in) :: pose
        type(figure_props), intent(in) :: props
        real(dp) :: uv(2, N_JOINTS)
        real(dp) :: hip_h, tr, dt(2), off(2), neck_p(2), d(2)

        hip_h = props%thigh + props%shin
        uv(:, J_ROOT) = [0.0_dp, 0.0_dp]
        uv(:, J_HIP_C) = [0.0_dp, hip_h]
        uv(:, J_HIP_L) = [-props%hip_half, hip_h]
        uv(:, J_HIP_R) = [props%hip_half, hip_h]

        ! Torso leans by the torso channel: dt = (sin, cos).
        tr = deg2rad(pose%ch(CH_TORSO))
        dt = [sin(tr), cos(tr)]
        neck_p = uv(:, J_HIP_C) + props%torso * dt
        uv(:, J_NECK) = neck_p
        ! Shoulder offset along the torso-perpendicular.
        off = props%shoulder_half * [cos(tr), sin(tr)]
        uv(:, J_SHOULDER_L) = neck_p - off
        uv(:, J_SHOULDER_R) = neck_p + off
        ! Head centre along the torso direction.
        uv(:, J_HEAD) = neck_p + (props%neck + props%head_r) * dt

        ! Arms (upper then fore, angles accumulate).
        d = limb_dir(pose%ch(CH_ARM_L_UPPER))
        uv(:, J_ELBOW_L) = uv(:, J_SHOULDER_L) + props%upper_arm * d
        d = limb_dir(pose%ch(CH_ARM_L_UPPER) + pose%ch(CH_ARM_L_FORE))
        uv(:, J_HAND_L) = uv(:, J_ELBOW_L) + props%fore_arm * d
        d = limb_dir(pose%ch(CH_ARM_R_UPPER))
        uv(:, J_ELBOW_R) = uv(:, J_SHOULDER_R) + props%upper_arm * d
        d = limb_dir(pose%ch(CH_ARM_R_UPPER) + pose%ch(CH_ARM_R_FORE))
        uv(:, J_HAND_R) = uv(:, J_ELBOW_R) + props%fore_arm * d

        ! Legs (thigh then shin, angles accumulate).
        d = limb_dir(pose%ch(CH_LEG_L_THIGH))
        uv(:, J_KNEE_L) = uv(:, J_HIP_L) + props%thigh * d
        d = limb_dir(pose%ch(CH_LEG_L_THIGH) + pose%ch(CH_LEG_L_SHIN))
        uv(:, J_FOOT_L) = uv(:, J_KNEE_L) + props%shin * d
        d = limb_dir(pose%ch(CH_LEG_R_THIGH))
        uv(:, J_KNEE_R) = uv(:, J_HIP_R) + props%thigh * d
        d = limb_dir(pose%ch(CH_LEG_R_THIGH) + pose%ch(CH_LEG_R_SHIN))
        uv(:, J_FOOT_R) = uv(:, J_KNEE_R) + props%shin * d
    end function figure_fk

    ! Billboard basis for a figure at root_pos seen from cam_pos.
    !   f     = normalize(cam_pos - root_pos, y zeroed); degenerate
    !           (camera directly overhead / coincident) -> (0,0,1).
    !   right = normalize(cross((0,1,0), f))
    ! (right, f) are then rotated around Y by root.face degrees (the
    ! authored facing offset).  up is always world (0,1,0): this is a
    ! cylindrical (yaw-only) billboard, so feet stay planted.
    pure subroutine figure_facing_basis(pose, root_pos, cam_pos, &
                                        right, fwd)
        type(figure_pose), intent(in) :: pose
        type(vec3), intent(in) :: root_pos, cam_pos
        type(vec3), intent(out) :: right, fwd
        type(vec3) :: f, r
        real(dp) :: n, a, ca, sa

        f = vec3_sub(cam_pos, root_pos)
        f%y = 0.0_dp
        n = vec3_norm(f)
        if (n < 1.0e-12_dp) then
            f = vec3_create(0.0_dp, 0.0_dp, 1.0_dp)
        else
            f = vec3_scale(f, 1.0_dp / n)
        end if
        r = vec3_normalize(vec3_cross(vec3_create(0.0_dp, 1.0_dp, &
                                                  0.0_dp), f))
        a = deg2rad(pose%ch(CH_ROOT_FACE))
        ca = cos(a)
        sa = sin(a)
        ! Rotate a horizontal vector about Y by a.
        right = vec3_create(r%x * ca + r%z * sa, 0.0_dp, &
                            -r%x * sa + r%z * ca)
        fwd = vec3_create(f%x * ca + f%z * sa, 0.0_dp, &
                          -f%x * sa + f%z * ca)
    end subroutine figure_facing_basis

    ! World-space joint positions:
    !   world(joint) = root_pos + right*u + (0,1,0)*v.
    pure function figure_joints_world(pose, props, root_pos, cam_pos) &
            result(w)
        type(figure_pose), intent(in) :: pose
        type(figure_props), intent(in) :: props
        type(vec3), intent(in) :: root_pos, cam_pos
        type(vec3) :: w(N_JOINTS)
        real(dp) :: uv(2, N_JOINTS)
        type(vec3) :: right, fwd
        integer :: j

        uv = figure_fk(pose, props)
        call figure_facing_basis(pose, root_pos, cam_pos, right, fwd)
        do j = 1, N_JOINTS
            w(j) = vec3_add(root_pos, &
                            vec3_add(vec3_scale(right, uv(1, j)), &
                                     vec3_create(0.0_dp, uv(2, j), &
                                                 0.0_dp)))
        end do
    end function figure_joints_world

    ! -----------------------------------------------------------------
    ! Mesh building (Approach A): one legacy Mesh in WORLD space.
    ! Limbs/torso/neck = capsules between joints; head = flat disc in
    ! the facing plane; face features, hair and wears are small
    ! discs/capsules parented to joints.  Everything is stamped with
    ! the BASIC (unlit) material so the figure reads as flat colour.
    ! -----------------------------------------------------------------
    subroutine figure_build_mesh(pose, props, identity, base_color, &
                                 cam_pos, mesh_out)
        type(figure_pose), intent(in) :: pose
        type(figure_props), intent(in) :: props
        type(figure_identity), intent(in) :: identity
        integer, intent(in) :: base_color(3)
        type(vec3), intent(in) :: cam_pos
        type(Mesh), intent(inout) :: mesh_out

        type(vec3) :: root_pos, right, fwd, up
        type(vec3) :: jw(N_JOINTS)
        integer :: basic_id, i
        integer :: torso_rgb(3), dress_rgb(3), cap_rgb(3), hat_rgb(3)
        integer :: glasses_rgb(3)
        logical :: has_dress, has_cap, has_hat, has_glasses
        real(dp) :: hr

        basic_id = material_id_from_name('basic')
        root_pos = vec3_create(pose%ch(CH_ROOT_X), pose%ch(CH_ROOT_Y), &
                               pose%ch(CH_ROOT_Z))
        jw = figure_joints_world(pose, props, root_pos, cam_pos)
        call figure_facing_basis(pose, root_pos, cam_pos, right, fwd)
        up = vec3_create(0.0_dp, 1.0_dp, 0.0_dp)
        hr = props%head_r

        if (allocated(mesh_out%triangles)) deallocate(mesh_out%triangles)
        mesh_out%num_triangles = 0

        ! Resolve wears first (they recolours / add body parts).
        torso_rgb = base_color
        dress_rgb = base_color
        cap_rgb = base_color
        hat_rgb = base_color
        glasses_rgb = [25, 25, 25]
        has_dress = .false.
        has_cap = .false.
        has_hat = .false.
        has_glasses = .false.
        do i = 1, identity%n_wears
            select case (trim(identity%wears(i)%item))
            case ('shirt')
                torso_rgb = identity%wears(i)%color
            case ('dress')
                has_dress = .true.
                dress_rgb = identity%wears(i)%color
                torso_rgb = identity%wears(i)%color
            case ('cap')
                has_cap = .true.
                cap_rgb = identity%wears(i)%color
            case ('hat')
                has_hat = .true.
                hat_rgb = identity%wears(i)%color
            case ('glasses')
                has_glasses = .true.
                if (any(identity%wears(i)%color /= [255, 255, 255])) &
                    glasses_rgb = identity%wears(i)%color
            end select
        end do

        ! ---- body capsules (joints in world space) ----
        call add_capsule_between(mesh_out, jw(J_HIP_L), jw(J_KNEE_L), &
                                 props%line_r, base_color, 8, basic_id)
        call add_capsule_between(mesh_out, jw(J_KNEE_L), jw(J_FOOT_L), &
                                 props%line_r, base_color, 8, basic_id)
        call add_capsule_between(mesh_out, jw(J_HIP_R), jw(J_KNEE_R), &
                                 props%line_r, base_color, 8, basic_id)
        call add_capsule_between(mesh_out, jw(J_KNEE_R), jw(J_FOOT_R), &
                                 props%line_r, base_color, 8, basic_id)
        call add_capsule_between(mesh_out, jw(J_HIP_C), jw(J_NECK), &
                                 props%line_r, torso_rgb, 8, basic_id)
        call add_capsule_between(mesh_out, jw(J_NECK), jw(J_HEAD), &
                                 props%line_r, base_color, 8, basic_id)
        call add_capsule_between(mesh_out, jw(J_SHOULDER_L), &
                                 jw(J_ELBOW_L), props%line_r, &
                                 base_color, 8, basic_id)
        call add_capsule_between(mesh_out, jw(J_ELBOW_L), jw(J_HAND_L), &
                                 props%line_r, base_color, 8, basic_id)
        call add_capsule_between(mesh_out, jw(J_SHOULDER_R), &
                                 jw(J_ELBOW_R), props%line_r, &
                                 base_color, 8, basic_id)
        call add_capsule_between(mesh_out, jw(J_ELBOW_R), jw(J_HAND_R), &
                                 props%line_r, base_color, 8, basic_id)
        ! Shoulder + hip bars (Wave 3 fix): the limb capsules start
        ! AT the shoulder/hip joints, which sit shoulder_half /
        ! hip_half away from the torso axis -- without bars the arms
        ! and legs read as detached from the torso by a visible gap.
        call add_capsule_between(mesh_out, jw(J_SHOULDER_L), &
                                 jw(J_SHOULDER_R), props%line_r, &
                                 torso_rgb, 8, basic_id)
        call add_capsule_between(mesh_out, jw(J_HIP_L), &
                                 jw(J_HIP_R), props%line_r, &
                                 base_color, 8, basic_id)

        ! ---- dress: cone fan from the neck to hip level, flaring ----
        if (has_dress) then
            call add_dress_cone(mesh_out, jw(J_NECK), jw(J_HIP_C), &
                                right, fwd, &
                                props%shoulder_half * 0.9_dp, &
                                props%hip_half * 2.6_dp, &
                                dress_rgb, basic_id)
        end if

        ! ---- head ----
        call add_head(mesh_out, jw(J_HEAD), right, up, fwd, hr, &
                      identity, base_color, basic_id)

        ! ---- hair (parented to the head) ----
        if (trim(identity%hair) == 'bun') then
            call add_disc(mesh_out, &
                plane_pt(jw(J_HEAD), right, up, fwd, 0.0_dp, &
                         0.82_dp * hr, -0.10_dp * hr), &
                right, up, fwd, 0.42_dp * hr, 1.0_dp, 0.0_dp, &
                identity%hair_color, 8, .false., basic_id)
            call add_disc(mesh_out, &
                plane_pt(jw(J_HEAD), right, up, fwd, -0.30_dp * hr, &
                         0.62_dp * hr, -0.08_dp * hr), &
                right, up, fwd, 0.26_dp * hr, 1.0_dp, 0.0_dp, &
                identity%hair_color, 8, .false., basic_id)
            call add_disc(mesh_out, &
                plane_pt(jw(J_HEAD), right, up, fwd, 0.30_dp * hr, &
                         0.62_dp * hr, -0.08_dp * hr), &
                right, up, fwd, 0.26_dp * hr, 1.0_dp, 0.0_dp, &
                identity%hair_color, 8, .false., basic_id)
        else if (trim(identity%hair) /= '') then
            ! Generic hair: a cap-like arc band over the top of the head.
            call add_band(mesh_out, jw(J_HEAD), right, up, fwd, &
                          0.70_dp * hr, 1.05_dp * hr, 15.0_dp, &
                          165.0_dp, 0.15_dp * props%line_r, &
                          identity%hair_color, 8, basic_id)
        end if

        ! ---- face features (expression from face.expr) ----
        call add_face(mesh_out, pose, jw(J_HEAD), right, up, fwd, hr, &
                      props, basic_id)

        ! ---- cap / hat (parented to the head) ----
        if (has_cap) then
            ! Dome centred above the eye line (centre +0.18 hr,
            ! radius 0.92 hr) so the eyes stay clear of the cap
            ! (Wave 3 fix: a centre-anchored half-disc covered the
            ! whole upper face).
            call add_fan(mesh_out, &
                         plane_pt(jw(J_HEAD), right, up, fwd, 0.0_dp, &
                                  0.18_dp * hr, 0.0_dp), &
                         right, up, fwd, &
                         0.92_dp * hr, 1.0_dp, 0.0_dp, 180.0_dp, &
                         0.20_dp * props%line_r, cap_rgb, 8, .false., &
                         basic_id)
            call add_disc(mesh_out, &
                plane_pt(jw(J_HEAD), right, up, fwd, 0.0_dp, &
                         0.52_dp * hr, 0.20_dp * props%line_r), &
                right, up, fwd, 1.18_dp * hr, 0.30_dp, 0.0_dp, &
                cap_rgb, 8, .false., basic_id)
        end if
        if (has_hat) then
            call add_disc(mesh_out, &
                plane_pt(jw(J_HEAD), right, up, fwd, 0.0_dp, &
                         0.42_dp * hr, 0.20_dp * props%line_r), &
                right, up, fwd, 1.28_dp * hr, 0.26_dp, 0.0_dp, &
                hat_rgb, 8, .false., basic_id)
            call add_capsule_between(mesh_out, &
                plane_pt(jw(J_HEAD), right, up, fwd, 0.0_dp, &
                         0.42_dp * hr, 0.0_dp), &
                plane_pt(jw(J_HEAD), right, up, fwd, 0.0_dp, &
                         1.02_dp * hr, 0.0_dp), &
                0.62_dp * hr, hat_rgb, 8, basic_id)
        end if

        ! ---- glasses (parented to the eyes) ----
        if (has_glasses) then
            call add_glasses(mesh_out, pose, jw(J_HEAD), right, up, &
                             fwd, hr, props, glasses_rgb, basic_id)
        end if

        ! ---- held prop: thin capsule from the right hand, forward ----
        if (trim(identity%holds) /= '') then
            call add_capsule_between(mesh_out, jw(J_HAND_R), &
                vec3_add(vec3_add(jw(J_HAND_R), &
                                  vec3_scale(fwd, 0.38_dp)), &
                         vec3_create(0.0_dp, -0.02_dp, 0.0_dp)), &
                props%line_r * 0.55_dp, [128, 105, 80], 4, basic_id)
        end if
    end subroutine figure_build_mesh

    ! Point in the figure plane: centre + right*u + up*v + fwd*z.
    pure function plane_pt(centre, right, up, fwd, u, v, z) result(p)
        type(vec3), intent(in) :: centre, right, up, fwd
        real(dp), intent(in) :: u, v, z
        type(vec3) :: p
        p = vec3_add(centre, vec3_add(vec3_scale(right, u), &
                     vec3_add(vec3_scale(up, v), vec3_scale(fwd, z))))
    end function plane_pt

    ! Capsule between two world points: build_capsule_data along Y
    ! (total length = dist when height = dist - 2r), rotated by the
    ! quaternion taking +Y to the limb direction, centred on the
    ! midpoint; merged with mesh_add_transformed, stamping colour and
    ! the BASIC material id on every triangle.
    subroutine add_capsule_between(msh, a, b, r, rgb, segments, mat_id)
        type(Mesh), intent(inout) :: msh
        type(vec3), intent(in) :: a, b
        real(dp), intent(in) :: r
        integer, intent(in) :: rgb(3), segments, mat_id
        type(mesh_data) :: md
        type(Mesh) :: tmp
        type(vec3) :: dir, axis, mid
        real(dp) :: len, ang
        type(quat) :: q
        type(mat4) :: model

        dir = vec3_sub(b, a)
        len = vec3_norm(dir)
        if (len < 1.0e-12_dp) return
        call build_capsule_data(md, r, max(len - 2.0_dp * r, 0.0_dp), &
                                segments)
        call mesh_data_to_triangles(md, tmp)
        call mesh_data_free(md)
        dir = vec3_scale(dir, 1.0_dp / len)
        axis = vec3_cross(vec3_create(0.0_dp, 1.0_dp, 0.0_dp), dir)
        if (vec3_norm(axis) < 1.0e-9_dp) then
            if (dir%y > 0.0_dp) then
                q = quat_identity()
            else
                q = quat_from_axis_angle(vec3_create(1.0_dp, 0.0_dp, &
                                                     0.0_dp), 180.0_dp)
            end if
        else
            ang = rad2deg(acos(max(-1.0_dp, min(1.0_dp, dir%y))))
            q = quat_from_axis_angle(axis, ang)
        end if
        model = quat_to_mat4(q)
        mid = vec3_scale(vec3_add(a, b), 0.5_dp)
        model%m(1, 4) = mid%x
        model%m(2, 4) = mid%y
        model%m(3, 4) = mid%z
        call mesh_add_transformed(msh, tmp, model, .true., rgb, mat_id)
        call free_mesh(tmp)
    end subroutine add_capsule_between

    ! One flat triangle, stamped with colour + material.
    subroutine push_tri(msh, a, b, c, rgb, mat_id)
        type(Mesh), intent(inout) :: msh
        type(vec3), intent(in) :: a, b, c
        integer, intent(in) :: rgb(3), mat_id
        type(Mesh) :: one
        type(vec3) :: n

        allocate(one%triangles(1))
        one%num_triangles = 1
        n = compute_triangle_normal(a, b, c)
        one%triangles(1)%v = [a, b, c]
        one%triangles(1)%normal = n
        one%triangles(1)%vn = [n, n, n]
        one%triangles(1)%smooth = .false.
        one%triangles(1)%color = rgb
        one%triangles(1)%material_id = mat_id
        call mesh_append(msh, one)
        call free_mesh(one)
    end subroutine push_tri

    ! Flat fan in the (right, up) plane around centre, angles
    ! a0..a1 degrees (0 = +u, 90 = +v), v-radius scaled by scale_v,
    ! offset toward the camera by zoff along fwd.
    subroutine add_fan(msh, centre, right, up, fwd, radius, scale_v, &
                       a0, a1, zoff, rgb, nseg, double_sided, mat_id)
        type(Mesh), intent(inout) :: msh
        type(vec3), intent(in) :: centre, right, up, fwd
        real(dp), intent(in) :: radius, scale_v, a0, a1, zoff
        integer, intent(in) :: rgb(3), nseg, mat_id
        logical, intent(in) :: double_sided
        type(vec3) :: c, p0, p1
        real(dp) :: t0, t1
        integer :: i

        c = plane_pt(centre, right, up, fwd, 0.0_dp, 0.0_dp, zoff)
        do i = 1, nseg
            t0 = deg2rad(a0 + (a1 - a0) * real(i - 1, dp) / &
                         real(nseg, dp))
            t1 = deg2rad(a0 + (a1 - a0) * real(i, dp) / &
                         real(nseg, dp))
            p0 = plane_pt(centre, right, up, fwd, &
                          radius * cos(t0), &
                          radius * scale_v * sin(t0), zoff)
            p1 = plane_pt(centre, right, up, fwd, &
                          radius * cos(t1), &
                          radius * scale_v * sin(t1), zoff)
            ! Winding: the billboard triad (right, up, fwd) is
            ! right-handed with fwd TOWARD the viewer, so a fan
            ! wound (c, p0, p1) in (u, v) order is back-facing in
            ! the renderers' y-down screen-space culling and is
            ! culled.  The visible order is (c, p1, p0) -- the
            ! same order the head disc's double-sided pair already
            ! rendered through (Wave 3 fix: cap/eyes/bun/glasses
            ! were single-sided in the culled order and vanished).
            call push_tri(msh, c, p1, p0, rgb, mat_id)
            if (double_sided) call push_tri(msh, c, p0, p1, rgb, &
                                            mat_id)
        end do
    end subroutine add_fan

    ! Full flat disc in the facing plane.
    subroutine add_disc(msh, centre, right, up, fwd, radius, scale_v, &
                        zoff, rgb, nseg, double_sided, mat_id)
        type(Mesh), intent(inout) :: msh
        type(vec3), intent(in) :: centre, right, up, fwd
        real(dp), intent(in) :: radius, scale_v, zoff
        integer, intent(in) :: rgb(3), nseg, mat_id
        logical, intent(in) :: double_sided
        call add_fan(msh, centre, right, up, fwd, radius, scale_v, &
                     0.0_dp, 360.0_dp, zoff, rgb, nseg, double_sided, &
                     mat_id)
    end subroutine add_disc

    ! Flat ring band between radii r1..r2 over angles a0..a1 degrees.
    subroutine add_band(msh, centre, right, up, fwd, r1, r2, a0, a1, &
                        zoff, rgb, nseg, mat_id)
        type(Mesh), intent(inout) :: msh
        type(vec3), intent(in) :: centre, right, up, fwd
        real(dp), intent(in) :: r1, r2, a0, a1, zoff
        integer, intent(in) :: rgb(3), nseg, mat_id
        type(vec3) :: q00, q01, q10, q11
        real(dp) :: t0, t1
        integer :: i

        do i = 1, nseg
            t0 = deg2rad(a0 + (a1 - a0) * real(i - 1, dp) / &
                         real(nseg, dp))
            t1 = deg2rad(a0 + (a1 - a0) * real(i, dp) / &
                         real(nseg, dp))
            q00 = plane_pt(centre, right, up, fwd, r1 * cos(t0), &
                           r1 * sin(t0), zoff)
            q01 = plane_pt(centre, right, up, fwd, r2 * cos(t0), &
                           r2 * sin(t0), zoff)
            q10 = plane_pt(centre, right, up, fwd, r1 * cos(t1), &
                           r1 * sin(t1), zoff)
            q11 = plane_pt(centre, right, up, fwd, r2 * cos(t1), &
                           r2 * sin(t1), zoff)
            ! Screen-facing winding, as in add_fan (Wave 3 fix).
            call push_tri(msh, q00, q11, q01, rgb, mat_id)
            call push_tri(msh, q00, q10, q11, rgb, mat_id)
        end do
    end subroutine add_band

    ! Head: flat disc in the facing plane (round), scaled v x1.2
    ! (oval), or a flat box (square: 12 tris via build_box_data,
    ! oriented by the (right, up, fwd) basis).
    subroutine add_head(msh, centre, right, up, fwd, hr, identity, &
                        rgb, mat_id)
        type(Mesh), intent(inout) :: msh
        type(vec3), intent(in) :: centre, right, up, fwd
        real(dp), intent(in) :: hr
        type(figure_identity), intent(in) :: identity
        integer, intent(in) :: rgb(3), mat_id
        type(mesh_data) :: md
        type(Mesh) :: tmp
        type(mat4) :: model

        select case (trim(identity%head_style))
        case ('square')
            call build_box_data(md, 2.0_dp * hr, 2.0_dp * hr, &
                                0.03_dp)
            call mesh_data_to_triangles(md, tmp)
            call mesh_data_free(md)
            model%m = 0.0_dp
            model%m(1, 1) = right%x
            model%m(2, 1) = right%y
            model%m(3, 1) = right%z
            model%m(1, 2) = up%x
            model%m(2, 2) = up%y
            model%m(3, 2) = up%z
            model%m(1, 3) = fwd%x
            model%m(2, 3) = fwd%y
            model%m(3, 3) = fwd%z
            model%m(1, 4) = centre%x
            model%m(2, 4) = centre%y
            model%m(3, 4) = centre%z
            model%m(4, 4) = 1.0_dp
            call mesh_add_transformed(msh, tmp, model, .true., rgb, &
                                      mat_id)
            call free_mesh(tmp)
        case ('oval')
            call add_disc(msh, centre, right, up, fwd, hr, 1.2_dp, &
                          0.0_dp, rgb, 16, .true., mat_id)
        case default  ! round
            call add_disc(msh, centre, right, up, fwd, hr, 1.0_dp, &
                          0.0_dp, rgb, 16, .true., mat_id)
        end select
    end subroutine add_head

    ! Face features on the head-disc plane, slightly toward the
    ! camera.  head.yaw shifts the features in u, head.pitch in v
    ! (the features slide on the disc -- the flat-figure convention).
    ! Mouth shape varies with face.expr: neutral/determined = straight
    ! capsule (short / long), happy = upturned (two angled capsules),
    ! sad = downturned, surprised = small open disc.
    subroutine add_face(msh, pose, centre, right, up, fwd, hr, props, &
                        mat_id)
        type(Mesh), intent(inout) :: msh
        type(figure_pose), intent(in) :: pose
        type(vec3), intent(in) :: centre, right, up, fwd
        real(dp), intent(in) :: hr
        type(figure_props), intent(in) :: props
        integer, intent(in) :: mat_id
        integer :: dark(3), expr
        real(dp) :: zoff, ush, vsh, eye_u, eye_v, mouth_v, mr
        type(vec3) :: mc, ml, mrgt

        dark = [25, 25, 25]
        zoff = 0.30_dp * props%line_r
        ush = sin(deg2rad(pose%ch(CH_HEAD_YAW))) * 0.25_dp * hr
        vsh = -sin(deg2rad(pose%ch(CH_HEAD_PITCH))) * 0.25_dp * hr
        eye_u = 0.35_dp * hr
        eye_v = 0.15_dp * hr + vsh
        mouth_v = -0.38_dp * hr + vsh
        mr = 0.06_dp * hr

        ! Eyes: two small discs (radius raised 0.11 -> 0.13 hr in
        ! the Wave 3 fix so the face reads at preview sizes).
        call add_disc(msh, &
            plane_pt(centre, right, up, fwd, ush - eye_u, eye_v, &
                     zoff), &
            right, up, fwd, 0.13_dp * hr, 1.0_dp, 0.0_dp, dark, 6, &
            .false., mat_id)
        call add_disc(msh, &
            plane_pt(centre, right, up, fwd, ush + eye_u, eye_v, &
                     zoff), &
            right, up, fwd, 0.13_dp * hr, 1.0_dp, 0.0_dp, dark, 6, &
            .false., mat_id)

        expr = nint(pose%ch(CH_FACE_EXPR))
        mc = plane_pt(centre, right, up, fwd, ush, mouth_v, zoff)
        select case (expr)
        case (EXPR_HAPPY)
            ml = plane_pt(centre, right, up, fwd, ush - 0.30_dp * hr, &
                          mouth_v + 0.10_dp * hr, zoff)
            mrgt = plane_pt(centre, right, up, fwd, &
                            ush + 0.30_dp * hr, &
                            mouth_v + 0.10_dp * hr, zoff)
            mc = plane_pt(centre, right, up, fwd, ush, &
                          mouth_v - 0.05_dp * hr, zoff)
            call add_capsule_between(msh, ml, mc, mr, dark, 4, mat_id)
            call add_capsule_between(msh, mc, mrgt, mr, dark, 4, &
                                     mat_id)
        case (EXPR_SAD)
            ml = plane_pt(centre, right, up, fwd, ush - 0.30_dp * hr, &
                          mouth_v - 0.10_dp * hr, zoff)
            mrgt = plane_pt(centre, right, up, fwd, &
                            ush + 0.30_dp * hr, &
                            mouth_v - 0.10_dp * hr, zoff)
            mc = plane_pt(centre, right, up, fwd, ush, &
                          mouth_v + 0.05_dp * hr, zoff)
            call add_capsule_between(msh, ml, mc, mr, dark, 4, mat_id)
            call add_capsule_between(msh, mc, mrgt, mr, dark, 4, &
                                     mat_id)
        case (EXPR_DETERMINED)
            ml = plane_pt(centre, right, up, fwd, ush - 0.30_dp * hr, &
                          mouth_v, zoff)
            mrgt = plane_pt(centre, right, up, fwd, &
                            ush + 0.30_dp * hr, mouth_v, zoff)
            call add_capsule_between(msh, ml, mrgt, mr, dark, 4, &
                                     mat_id)
        case (EXPR_SURPRISED)
            call add_disc(msh, mc, right, up, fwd, 0.14_dp * hr, &
                          1.0_dp, 0.0_dp, dark, 8, .false., mat_id)
        case default  ! neutral: straight, short
            ml = plane_pt(centre, right, up, fwd, ush - 0.18_dp * hr, &
                          mouth_v, zoff)
            mrgt = plane_pt(centre, right, up, fwd, &
                            ush + 0.18_dp * hr, mouth_v, zoff)
            call add_capsule_between(msh, ml, mrgt, mr, dark, 4, &
                                     mat_id)
        end select
    end subroutine add_face

    ! Glasses: two ring discs in front of the eyes + a bridge quad.
    subroutine add_glasses(msh, pose, centre, right, up, fwd, hr, &
                           props, rgb, mat_id)
        type(Mesh), intent(inout) :: msh
        type(figure_pose), intent(in) :: pose
        type(vec3), intent(in) :: centre, right, up, fwd
        real(dp), intent(in) :: hr
        type(figure_props), intent(in) :: props
        integer, intent(in) :: rgb(3), mat_id
        real(dp) :: zoff, ush, vsh, eye_u, eye_v
        type(vec3) :: q00, q01, q10, q11

        zoff = 0.45_dp * props%line_r
        ush = sin(deg2rad(pose%ch(CH_HEAD_YAW))) * 0.25_dp * hr
        vsh = -sin(deg2rad(pose%ch(CH_HEAD_PITCH))) * 0.25_dp * hr
        eye_u = 0.35_dp * hr
        eye_v = 0.15_dp * hr + vsh
        call add_band(msh, &
            plane_pt(centre, right, up, fwd, ush - eye_u, eye_v, &
                     0.0_dp), &
            right, up, fwd, 0.20_dp * hr, 0.28_dp * hr, 0.0_dp, &
            360.0_dp, zoff, rgb, 8, mat_id)
        call add_band(msh, &
            plane_pt(centre, right, up, fwd, ush + eye_u, eye_v, &
                     0.0_dp), &
            right, up, fwd, 0.20_dp * hr, 0.28_dp * hr, 0.0_dp, &
            360.0_dp, zoff, rgb, 8, mat_id)
        ! Bridge between the rings.
        q00 = plane_pt(centre, right, up, fwd, ush - 0.16_dp * hr, &
                       eye_v - 0.03_dp * hr, zoff)
        q01 = plane_pt(centre, right, up, fwd, ush - 0.16_dp * hr, &
                       eye_v + 0.03_dp * hr, zoff)
        q10 = plane_pt(centre, right, up, fwd, ush + 0.16_dp * hr, &
                       eye_v - 0.03_dp * hr, zoff)
        q11 = plane_pt(centre, right, up, fwd, ush + 0.16_dp * hr, &
                       eye_v + 0.03_dp * hr, zoff)
        ! Screen-facing winding, as in add_fan (Wave 3 fix).
        call push_tri(msh, q00, q11, q01, rgb, mat_id)
        call push_tri(msh, q00, q10, q11, rgb, mat_id)
    end subroutine add_glasses

    ! Dress: open cone fan from a ring at the neck to a wider ring at
    ! hip level, around the neck->hip axis in the facing plane.
    subroutine add_dress_cone(msh, neck_w, hip_w, right, fwd, r_top, &
                              r_bot, rgb, mat_id)
        type(Mesh), intent(inout) :: msh
        type(vec3), intent(in) :: neck_w, hip_w, right, fwd
        real(dp), intent(in) :: r_top, r_bot
        integer, intent(in) :: rgb(3), mat_id
        integer, parameter :: NSEG = 12
        type(vec3) :: t0, t1, b0, b1
        real(dp) :: a0, a1
        integer :: i

        do i = 1, NSEG
            a0 = 2.0_dp * PI * real(i - 1, dp) / real(NSEG, dp)
            a1 = 2.0_dp * PI * real(i, dp) / real(NSEG, dp)
            t0 = vec3_add(neck_w, vec3_add(vec3_scale(right, &
                          r_top * cos(a0)), vec3_scale(fwd, &
                          r_top * sin(a0))))
            t1 = vec3_add(neck_w, vec3_add(vec3_scale(right, &
                          r_top * cos(a1)), vec3_scale(fwd, &
                          r_top * sin(a1))))
            b0 = vec3_add(hip_w, vec3_add(vec3_scale(right, &
                          r_bot * cos(a0)), vec3_scale(fwd, &
                          r_bot * sin(a0))))
            b1 = vec3_add(hip_w, vec3_add(vec3_scale(right, &
                          r_bot * cos(a1)), vec3_scale(fwd, &
                          r_bot * sin(a1))))
            call push_tri(msh, t0, b0, b1, rgb, mat_id)
            call push_tri(msh, t0, b1, t1, rgb, mat_id)
        end do
    end subroutine add_dress_cone

end module char_figure_3d
