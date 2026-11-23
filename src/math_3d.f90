module math_3d
    use, intrinsic :: iso_fortran_env, only: dp => real64
    implicit none
    private
    public :: dp, vec3, mat4, &
              deg2rad, rad2deg, &
              vec3_create, vec3_add, vec3_sub, vec3_scale, vec3_dot, vec3_cross, vec3_norm, vec3_normalize, &
              vec3_negate, vec3_lerp, vec3_reflect, &
              mat4_identity, mat4_mult, mat4_translation, mat4_scale, &
              mat4_rotate_x, mat4_rotate_y, mat4_rotate_z, &
              mat4_transpose, mat4_axis_angle, mat4_compose_trs, mat4_inverse_rigid, &
              mat4_determinant, mat4_reflect_axis, &
              mat4_perspective, mat4_look_at, mat4_transform_vec3
    ! --- v3.0 Phase 5 additions (additive only; see the Phase 5
    ! section header below for the conventions) ---
    public :: vec4, mat3, quat
    public :: vec4_create, vec4_add, vec4_sub, vec4_scale, vec4_dot, &
              vec4_norm, vec4_length, vec4_normalize, vec4_negate
    public :: mat3_identity, mat3_create, mat3_from_mat4, mat3_to_mat4, &
              mat3_mult, mat3_mult_vec3, mat3_transpose, &
              mat3_determinant, mat3_inverse
    public :: quat_create, quat_identity, quat_from_axis_angle, &
              quat_from_euler, quat_to_euler, quat_multiply, &
              quat_conjugate, quat_inverse, quat_normalize, quat_dot, &
              quat_add, quat_sub, quat_scale, quat_negate, &
              quat_rotate_vec3, quat_to_mat4, quat_to_mat3, &
              quat_from_mat4, quat_from_mat3, quat_slerp
    public :: mat4_inverse
    public :: operator(*), operator(+), operator(-)

    real(dp), parameter, public :: PI = 3.14159265358979323846_dp

    type :: vec3
        real(dp) :: x = 0.0_dp
        real(dp) :: y = 0.0_dp
        real(dp) :: z = 0.0_dp
    end type vec3

    type :: mat4
        real(dp) :: m(4, 4) = 0.0_dp
    end type mat4

    ! ==================================================================
    ! v3.0 Phase 5 -- vec4 / mat3 / quat / general mat4_inverse
    ! ==================================================================
    ! CONVENTIONS (stated once, for the whole Phase 5 section):
    !
    ! * Matrices use the same storage as mat4: m(row, col), acting on
    !   COLUMN vectors (v' = M v); translation lives in column 4.
    !   mat3 mirrors this with m(3, 3).
    ! * quat components are (x, y, z, w) with the SCALAR PART LAST
    !   (w).  Unit quaternions represent rotations; q and -q are the
    !   same rotation.
    ! * quat_multiply(a, b) is the HAMILTON product a (x) b, and it
    !   APPLIES b FIRST, then a -- exactly like mat4_mult(a, b):
    !   quat_rotate_vec3(a*b, v) == quat_rotate_vec3(a,
    !   quat_rotate_vec3(b, v)).
    ! * Euler angles are in DEGREES, as a vec3 (x, y, z) = (pitch,
    !   yaw, roll), with the SAME order as mat4_compose_trs:
    !   R = Ry(y) * Rx(x) * Rz(z), i.e. roll is applied first, then
    !   pitch, then yaw.  Correspondingly
    !   quat_from_euler(e) = qy (x) qx (x) qz.
    ! * quat_to_euler is the inverse map for that order:
    !   x = asin(clamp(-R(2,3))); when |sin x| < 1 - 1e-12,
    !   y = atan2(R(1,3), R(3,3)) and z = atan2(R(2,1), R(2,2)).
    !   At the gimbal singularity (pitch = +/-90 deg) roll is not
    !   separable from yaw: z is returned as 0 and the combined
    !   yaw is folded into y (y = atan2(R(1,2), R(1,1)) for
    !   pitch +90, atan2(-R(1,2), R(1,1)) for pitch -90), so
    !   euler -> quat -> euler -> quat is always the identity on
    !   rotations even though the Euler triple itself may change.
    ! * Singular-inverse policy (mat3_inverse / mat4_inverse): when
    !   the determinant is exactly 0 the result is the IDENTITY and
    !   the ok flag is set .false.; otherwise ok is .true.
    !   mat4_inverse's ok is a required argument (pinned signature);
    !   mat3_inverse's ok is OPTIONAL (absent = caller does not
    !   check), matching the "optional ok flag" pattern.
    ! * The two inverse functions are NOT pure, unlike the rest of
    !   this module: a pure function's dummy arguments must all be
    !   intent(in), so an intent(out) ok flag cannot coexist with
    !   pure.  The (m, ok) signature wins; purity is dropped for
    !   these two functions only and recorded here as a deliberate
    !   deviation from the module's all-pure style.
    ! * Operator overloads exist ONLY for the new types:
    !   quat*quat, mat3*mat3, mat3*vec3, vec4+vec4, vec4-vec4,
    !   quat+quat, quat-quat.  No operator is defined for vec3 or
    !   mat4, so no existing expression changes meaning.

    type :: vec4
        real(dp) :: x = 0.0_dp
        real(dp) :: y = 0.0_dp
        real(dp) :: z = 0.0_dp
        real(dp) :: w = 0.0_dp
    end type vec4

    type :: mat3
        real(dp) :: m(3, 3) = 0.0_dp
    end type mat3

    type :: quat
        real(dp) :: x = 0.0_dp
        real(dp) :: y = 0.0_dp
        real(dp) :: z = 0.0_dp
        real(dp) :: w = 1.0_dp
    end type quat

    interface operator(*)
        module procedure quat_multiply
        module procedure mat3_mult
        module procedure mat3_mult_vec3
    end interface

    interface operator(+)
        module procedure vec4_add
        module procedure quat_add
    end interface

    interface operator(-)
        module procedure vec4_sub
        module procedure quat_sub
    end interface

contains

    pure function deg2rad(deg) result(rad)
        real(dp), intent(in) :: deg
        real(dp) :: rad
        rad = deg * PI / 180.0_dp
    end function deg2rad

    pure function rad2deg(rad) result(deg)
        real(dp), intent(in) :: rad
        real(dp) :: deg
        deg = rad * 180.0_dp / PI
    end function rad2deg

    pure function vec3_create(x, y, z) result(v)
        real(dp), intent(in) :: x, y, z
        type(vec3) :: v
        v%x = x; v%y = y; v%z = z
    end function vec3_create

    pure function vec3_add(a, b) result(c)
        type(vec3), intent(in) :: a, b
        type(vec3) :: c
        c%x = a%x + b%x
        c%y = a%y + b%y
        c%z = a%z + b%z
    end function vec3_add

    pure function vec3_sub(a, b) result(c)
        type(vec3), intent(in) :: a, b
        type(vec3) :: c
        c%x = a%x - b%x
        c%y = a%y - b%y
        c%z = a%z - b%z
    end function vec3_sub

    pure function vec3_scale(v, s) result(r)
        type(vec3), intent(in) :: v
        real(dp), intent(in) :: s
        type(vec3) :: r
        r%x = v%x * s
        r%y = v%y * s
        r%z = v%z * s
    end function vec3_scale

    pure function vec3_dot(a, b) result(d)
        type(vec3), intent(in) :: a, b
        real(dp) :: d
        d = a%x * b%x + a%y * b%y + a%z * b%z
    end function vec3_dot

    pure function vec3_cross(a, b) result(c)
        type(vec3), intent(in) :: a, b
        type(vec3) :: c
        c%x = a%y * b%z - a%z * b%y
        c%y = a%z * b%x - a%x * b%z
        c%z = a%x * b%y - a%y * b%x
    end function vec3_cross

    pure function vec3_norm(v) result(n)
        type(vec3), intent(in) :: v
        real(dp) :: n
        n = sqrt(vec3_dot(v, v))
    end function vec3_norm

    pure function vec3_normalize(v) result(r)
        type(vec3), intent(in) :: v
        type(vec3) :: r
        real(dp) :: l
        l = vec3_norm(v)
        if (l > 1.0e-12_dp) then
            r = vec3_scale(v, 1.0_dp / l)
        else
            r = vec3_create(0.0_dp, 0.0_dp, 0.0_dp)
        end if
    end function vec3_normalize

    pure function vec3_negate(v) result(r)
        type(vec3), intent(in) :: v
        type(vec3) :: r
        r%x = -v%x
        r%y = -v%y
        r%z = -v%z
    end function vec3_negate

    pure function vec3_lerp(a, b, t) result(r)
        type(vec3), intent(in) :: a, b
        real(dp), intent(in) :: t
        type(vec3) :: r
        r%x = a%x + (b%x - a%x) * t
        r%y = a%y + (b%y - a%y) * t
        r%z = a%z + (b%z - a%z) * t
    end function vec3_lerp

    pure function vec3_reflect(v, n) result(r)
        type(vec3), intent(in) :: v, n
        type(vec3) :: r
        r = vec3_sub(v, vec3_scale(n, 2.0_dp * vec3_dot(v, n)))
    end function vec3_reflect

    pure function mat4_identity() result(res)
        type(mat4) :: res
        integer :: i
        res%m = 0.0_dp
        do i = 1, 4
            res%m(i, i) = 1.0_dp
        end do
    end function mat4_identity

    pure function mat4_mult(a, b) result(c)
        type(mat4), intent(in) :: a, b
        type(mat4) :: c
        integer :: i, j, k
        c%m = 0.0_dp
        do i = 1, 4
            do j = 1, 4
                do k = 1, 4
                    c%m(i, j) = c%m(i, j) + a%m(i, k) * b%m(k, j)
                end do
            end do
        end do
    end function mat4_mult

    pure function mat4_translation(tx, ty, tz) result(t)
        real(dp), intent(in) :: tx, ty, tz
        type(mat4) :: t
        t = mat4_identity()
        t%m(1, 4) = tx
        t%m(2, 4) = ty
        t%m(3, 4) = tz
    end function mat4_translation

    pure function mat4_scale(sx, sy, sz) result(s)
        real(dp), intent(in) :: sx, sy, sz
        type(mat4) :: s
        s = mat4_identity()
        s%m(1, 1) = sx
        s%m(2, 2) = sy
        s%m(3, 3) = sz
    end function mat4_scale

    pure function mat4_rotate_x(angle_rad) result(r)
        real(dp), intent(in) :: angle_rad
        type(mat4) :: r
        r = mat4_identity()
        r%m(2, 2) = cos(angle_rad)
        r%m(2, 3) = -sin(angle_rad)
        r%m(3, 2) = sin(angle_rad)
        r%m(3, 3) = cos(angle_rad)
    end function mat4_rotate_x

    pure function mat4_rotate_y(angle_rad) result(r)
        real(dp), intent(in) :: angle_rad
        type(mat4) :: r
        r = mat4_identity()
        r%m(1, 1) = cos(angle_rad)
        r%m(1, 3) = sin(angle_rad)
        r%m(3, 1) = -sin(angle_rad)
        r%m(3, 3) = cos(angle_rad)
    end function mat4_rotate_y

    pure function mat4_rotate_z(angle_rad) result(r)
        real(dp), intent(in) :: angle_rad
        type(mat4) :: r
        r = mat4_identity()
        r%m(1, 1) = cos(angle_rad)
        r%m(1, 2) = -sin(angle_rad)
        r%m(2, 1) = sin(angle_rad)
        r%m(2, 2) = cos(angle_rad)
    end function mat4_rotate_z

    pure function mat4_transpose(m) result(r)
        type(mat4), intent(in) :: m
        type(mat4) :: r
        integer :: i, j
        do i = 1, 4
            do j = 1, 4
                r%m(i, j) = m%m(j, i)
            end do
        end do
    end function mat4_transpose

    pure function mat4_axis_angle(axis, angle_deg) result(r)
        type(vec3), intent(in) :: axis
        real(dp), intent(in) :: angle_deg
        type(mat4) :: r
        type(vec3) :: a
        real(dp) :: angle_rad, c, s, t

        a = vec3_normalize(axis)
        if (vec3_norm(a) <= 1.0e-12_dp) then
            r = mat4_identity()
            return
        end if

        angle_rad = deg2rad(angle_deg)
        c = cos(angle_rad)
        s = sin(angle_rad)
        t = 1.0_dp - c

        r = mat4_identity()
        r%m(1, 1) = t * a%x * a%x + c
        r%m(1, 2) = t * a%x * a%y - s * a%z
        r%m(1, 3) = t * a%x * a%z + s * a%y
        r%m(2, 1) = t * a%y * a%x + s * a%z
        r%m(2, 2) = t * a%y * a%y + c
        r%m(2, 3) = t * a%y * a%z - s * a%x
        r%m(3, 1) = t * a%z * a%x - s * a%y
        r%m(3, 2) = t * a%z * a%y + s * a%x
        r%m(3, 3) = t * a%z * a%z + c
    end function mat4_axis_angle

    pure function mat4_compose_trs(pos, rot_deg, scl) result(r)
        type(vec3), intent(in) :: pos, rot_deg, scl
        type(mat4) :: r
        r = mat4_mult(mat4_translation(pos%x, pos%y, pos%z), &
                      mat4_rotate_y(deg2rad(rot_deg%y)))
        r = mat4_mult(r, mat4_rotate_x(deg2rad(rot_deg%x)))
        r = mat4_mult(r, mat4_rotate_z(deg2rad(rot_deg%z)))
        r = mat4_mult(r, mat4_scale(scl%x, scl%y, scl%z))
    end function mat4_compose_trs

    ! Determinant of the linear (upper 3x3) part.  For the affine
    ! model matrices used here (bottom row 0 0 0 1) this equals the
    ! full 4x4 determinant; its SIGN is what matters: negative means
    ! the transform flips orientation (reflection / odd number of
    ! negative scale axes).
    pure function mat4_determinant(m) result(d)
        type(mat4), intent(in) :: m
        real(dp) :: d
        d = m%m(1, 1) * (m%m(2, 2) * m%m(3, 3) - m%m(2, 3) * m%m(3, 2)) &
          - m%m(1, 2) * (m%m(2, 1) * m%m(3, 3) - m%m(2, 3) * m%m(3, 1)) &
          + m%m(1, 3) * (m%m(2, 1) * m%m(3, 2) - m%m(2, 2) * m%m(3, 1))
    end function mat4_determinant

    ! Reflection across the coordinate plane through the origin
    ! perpendicular to the named axis: axis 1 = x (negate x),
    ! 2 = y, 3 = z.  Any other value gives the identity.
    pure function mat4_reflect_axis(axis) result(r)
        integer, intent(in) :: axis
        type(mat4) :: r
        r = mat4_identity()
        if (axis >= 1 .and. axis <= 3) r%m(axis, axis) = -1.0_dp
    end function mat4_reflect_axis

    pure function mat4_inverse_rigid(m) result(r)
        type(mat4), intent(in) :: m
        type(mat4) :: r
        integer :: i, j
        r = mat4_identity()
        do i = 1, 3
            do j = 1, 3
                r%m(i, j) = m%m(j, i)
            end do
        end do
        do i = 1, 3
            r%m(i, 4) = -(r%m(i, 1) * m%m(1, 4) + r%m(i, 2) * m%m(2, 4) + r%m(i, 3) * m%m(3, 4))
        end do
    end function mat4_inverse_rigid

    pure function mat4_perspective(fov_rad, aspect, near, far) result(p)
        real(dp), intent(in) :: fov_rad, aspect, near, far
        type(mat4) :: p
        real(dp) :: tan_half_fov
        p%m = 0.0_dp
        tan_half_fov = tan(fov_rad * 0.5_dp)
        p%m(1, 1) = 1.0_dp / (aspect * tan_half_fov)
        p%m(2, 2) = 1.0_dp / tan_half_fov
        p%m(3, 3) = -(far + near) / (far - near)
        p%m(3, 4) = -(2.0_dp * far * near) / (far - near)
        p%m(4, 3) = -1.0_dp
    end function mat4_perspective

    pure function mat4_look_at(eye, target, up) result(v)
        type(vec3), intent(in) :: eye, target, up
        type(mat4) :: v
        type(vec3) :: f, r, u, up_eff
        real(dp) :: f_dot_up

        f = vec3_normalize(vec3_sub(target, eye))
        ! Degenerate case (M1, v3.0 Phase 0): when the view direction
        ! is (anti-)parallel to up -- e.g. a top-down camera at
        ! (0,5,0) looking at the origin with the usual up (0,1,0) --
        ! cross(f, up) is the zero vector and the right/up rows of
        ! the result used to come out all-zero (a degenerate matrix).
        ! Substitute a fallback up perpendicular to f instead: the
        ! world Z axis, signed so it keeps a positive component along
        ! the caller's up where possible.  Non-degenerate inputs take
        ! exactly the pre-M1 path (bit-identical results).  A zero up
        ! vector gets the same treatment via the (0,1,0) default.
        up_eff = up
        if (vec3_norm(up_eff) <= 1.0e-12_dp) &
            up_eff = vec3_create(0.0_dp, 1.0_dp, 0.0_dp)
        f_dot_up = vec3_dot(f, vec3_normalize(up_eff))
        if (abs(f_dot_up) > 1.0_dp - 1.0e-10_dp) then
            if (f_dot_up >= 0.0_dp) then
                up_eff = vec3_create(0.0_dp, 0.0_dp, 1.0_dp)
            else
                up_eff = vec3_create(0.0_dp, 0.0_dp, -1.0_dp)
            end if
        end if
        r = vec3_normalize(vec3_cross(f, up_eff))
        u = vec3_cross(r, f)

        v%m = 0.0_dp
        v%m(1, 1) = r%x;  v%m(1, 2) = r%y;  v%m(1, 3) = r%z;  v%m(1, 4) = -vec3_dot(r, eye)
        v%m(2, 1) = u%x;  v%m(2, 2) = u%y;  v%m(2, 3) = u%z;  v%m(2, 4) = -vec3_dot(u, eye)
        v%m(3, 1) = -f%x; v%m(3, 2) = -f%y; v%m(3, 3) = -f%z; v%m(3, 4) = vec3_dot(f, eye)
        v%m(4, 4) = 1.0_dp
    end function mat4_look_at

    pure function mat4_transform_vec3(m, v, is_point) result(r)
        type(mat4), intent(in) :: m
        type(vec3), intent(in) :: v
        logical, intent(in) :: is_point
        type(vec3) :: r
        real(dp) :: w, w_coord

        w_coord = 0.0_dp
        if (is_point) w_coord = 1.0_dp

        r%x = m%m(1, 1) * v%x + m%m(1, 2) * v%y + m%m(1, 3) * v%z + m%m(1, 4) * w_coord
        r%y = m%m(2, 1) * v%x + m%m(2, 2) * v%y + m%m(2, 3) * v%z + m%m(2, 4) * w_coord
        r%z = m%m(3, 1) * v%x + m%m(3, 2) * v%y + m%m(3, 3) * v%z + m%m(3, 4) * w_coord
        w   = m%m(4, 1) * v%x + m%m(4, 2) * v%y + m%m(4, 3) * v%z + m%m(4, 4) * w_coord

        if (is_point .and. abs(w) > 1.0e-12_dp) then
            r%x = r%x / w
            r%y = r%y / w
            r%z = r%z / w
        end if
    end function mat4_transform_vec3

    ! ==================================================================
    ! Phase 5: vec4
    ! ==================================================================

    pure function vec4_create(x, y, z, w) result(v)
        real(dp), intent(in) :: x, y, z, w
        type(vec4) :: v
        v%x = x; v%y = y; v%z = z; v%w = w
    end function vec4_create

    pure function vec4_add(a, b) result(c)
        type(vec4), intent(in) :: a, b
        type(vec4) :: c
        c%x = a%x + b%x; c%y = a%y + b%y
        c%z = a%z + b%z; c%w = a%w + b%w
    end function vec4_add

    pure function vec4_sub(a, b) result(c)
        type(vec4), intent(in) :: a, b
        type(vec4) :: c
        c%x = a%x - b%x; c%y = a%y - b%y
        c%z = a%z - b%z; c%w = a%w - b%w
    end function vec4_sub

    pure function vec4_scale(v, s) result(r)
        type(vec4), intent(in) :: v
        real(dp), intent(in) :: s
        type(vec4) :: r
        r%x = v%x * s; r%y = v%y * s
        r%z = v%z * s; r%w = v%w * s
    end function vec4_scale

    pure function vec4_negate(v) result(r)
        type(vec4), intent(in) :: v
        type(vec4) :: r
        r%x = -v%x; r%y = -v%y; r%z = -v%z; r%w = -v%w
    end function vec4_negate

    pure function vec4_dot(a, b) result(d)
        type(vec4), intent(in) :: a, b
        real(dp) :: d
        d = a%x * b%x + a%y * b%y + a%z * b%z + a%w * b%w
    end function vec4_dot

    pure function vec4_norm(v) result(n)
        type(vec4), intent(in) :: v
        real(dp) :: n
        n = sqrt(vec4_dot(v, v))
    end function vec4_norm

    ! "length" spelling of vec4_norm (vec3 calls it _norm; both
    ! names are provided for vec4).
    pure function vec4_length(v) result(n)
        type(vec4), intent(in) :: v
        real(dp) :: n
        n = vec4_norm(v)
    end function vec4_length

    pure function vec4_normalize(v) result(r)
        type(vec4), intent(in) :: v
        type(vec4) :: r
        real(dp) :: l
        l = vec4_norm(v)
        if (l > 1.0e-12_dp) then
            r = vec4_scale(v, 1.0_dp / l)
        else
            r = vec4_create(0.0_dp, 0.0_dp, 0.0_dp, 0.0_dp)
        end if
    end function vec4_normalize

    ! ==================================================================
    ! Phase 5: mat3  (m(row, col), column vectors -- as mat4)
    ! ==================================================================

    pure function mat3_identity() result(res)
        type(mat3) :: res
        integer :: i
        res%m = 0.0_dp
        do i = 1, 3
            res%m(i, i) = 1.0_dp
        end do
    end function mat3_identity

    pure function mat3_create(m11, m12, m13, m21, m22, m23, &
                              m31, m32, m33) result(r)
        real(dp), intent(in) :: m11, m12, m13, m21, m22, m23
        real(dp), intent(in) :: m31, m32, m33
        type(mat3) :: r
        r%m(1, 1) = m11; r%m(1, 2) = m12; r%m(1, 3) = m13
        r%m(2, 1) = m21; r%m(2, 2) = m22; r%m(2, 3) = m23
        r%m(3, 1) = m31; r%m(3, 2) = m32; r%m(3, 3) = m33
    end function mat3_create

    pure function mat3_from_mat4(m) result(r)
        type(mat4), intent(in) :: m
        type(mat3) :: r
        r%m = m%m(1:3, 1:3)
    end function mat3_from_mat4

    pure function mat3_to_mat4(m) result(r)
        type(mat3), intent(in) :: m
        type(mat4) :: r
        r = mat4_identity()
        r%m(1:3, 1:3) = m%m
    end function mat3_to_mat4

    pure function mat3_mult(a, b) result(c)
        type(mat3), intent(in) :: a, b
        type(mat3) :: c
        integer :: i, j, k
        c%m = 0.0_dp
        do i = 1, 3
            do j = 1, 3
                do k = 1, 3
                    c%m(i, j) = c%m(i, j) + a%m(i, k) * b%m(k, j)
                end do
            end do
        end do
    end function mat3_mult

    pure function mat3_mult_vec3(m, v) result(r)
        type(mat3), intent(in) :: m
        type(vec3), intent(in) :: v
        type(vec3) :: r
        r%x = m%m(1, 1) * v%x + m%m(1, 2) * v%y + m%m(1, 3) * v%z
        r%y = m%m(2, 1) * v%x + m%m(2, 2) * v%y + m%m(2, 3) * v%z
        r%z = m%m(3, 1) * v%x + m%m(3, 2) * v%y + m%m(3, 3) * v%z
    end function mat3_mult_vec3

    pure function mat3_transpose(m) result(r)
        type(mat3), intent(in) :: m
        type(mat3) :: r
        integer :: i, j
        do i = 1, 3
            do j = 1, 3
                r%m(i, j) = m%m(j, i)
            end do
        end do
    end function mat3_transpose

    pure function mat3_determinant(m) result(d)
        type(mat3), intent(in) :: m
        real(dp) :: d
        d = m%m(1, 1) * (m%m(2, 2) * m%m(3, 3) - m%m(2, 3) * m%m(3, 2)) &
          - m%m(1, 2) * (m%m(2, 1) * m%m(3, 3) - m%m(2, 3) * m%m(3, 1)) &
          + m%m(1, 3) * (m%m(2, 1) * m%m(3, 2) - m%m(2, 2) * m%m(3, 1))
    end function mat3_determinant

    ! Inverse via the adjugate.  Singular guard (see the section
    ! header): determinant exactly 0 -> identity result; the
    ! OPTIONAL ok flag reports .false. in that case, .true.
    ! otherwise.  Not pure: see the header note on the ok flag.
    function mat3_inverse(m, ok) result(r)
        type(mat3), intent(in) :: m
        logical, intent(out), optional :: ok
        type(mat3) :: r
        real(dp) :: det, inv_det
        det = mat3_determinant(m)
        if (abs(det) > 0.0_dp) then
            if (present(ok)) ok = .true.
        else
            r = mat3_identity()
            if (present(ok)) ok = .false.
            return
        end if
        inv_det = 1.0_dp / det
        r%m(1, 1) =  (m%m(2, 2) * m%m(3, 3) - m%m(2, 3) * m%m(3, 2)) * inv_det
        r%m(1, 2) = -(m%m(1, 2) * m%m(3, 3) - m%m(1, 3) * m%m(3, 2)) * inv_det
        r%m(1, 3) =  (m%m(1, 2) * m%m(2, 3) - m%m(1, 3) * m%m(2, 2)) * inv_det
        r%m(2, 1) = -(m%m(2, 1) * m%m(3, 3) - m%m(2, 3) * m%m(3, 1)) * inv_det
        r%m(2, 2) =  (m%m(1, 1) * m%m(3, 3) - m%m(1, 3) * m%m(3, 1)) * inv_det
        r%m(2, 3) = -(m%m(1, 1) * m%m(2, 3) - m%m(1, 3) * m%m(2, 1)) * inv_det
        r%m(3, 1) =  (m%m(2, 1) * m%m(3, 2) - m%m(2, 2) * m%m(3, 1)) * inv_det
        r%m(3, 2) = -(m%m(1, 1) * m%m(3, 2) - m%m(1, 2) * m%m(3, 1)) * inv_det
        r%m(3, 3) =  (m%m(1, 1) * m%m(2, 2) - m%m(1, 2) * m%m(2, 1)) * inv_det
    end function mat3_inverse

    ! ==================================================================
    ! Phase 5: quat  ((x, y, z, w), scalar w LAST -- see header)
    ! ==================================================================

    pure function quat_create(x, y, z, w) result(q)
        real(dp), intent(in) :: x, y, z, w
        type(quat) :: q
        q%x = x; q%y = y; q%z = z; q%w = w
    end function quat_create

    pure function quat_identity() result(q)
        type(quat) :: q
        q = quat_create(0.0_dp, 0.0_dp, 0.0_dp, 1.0_dp)
    end function quat_identity

    pure function quat_add(a, b) result(c)
        type(quat), intent(in) :: a, b
        type(quat) :: c
        c%x = a%x + b%x; c%y = a%y + b%y
        c%z = a%z + b%z; c%w = a%w + b%w
    end function quat_add

    pure function quat_sub(a, b) result(c)
        type(quat), intent(in) :: a, b
        type(quat) :: c
        c%x = a%x - b%x; c%y = a%y - b%y
        c%z = a%z - b%z; c%w = a%w - b%w
    end function quat_sub

    pure function quat_scale(q, s) result(r)
        type(quat), intent(in) :: q
        real(dp), intent(in) :: s
        type(quat) :: r
        r%x = q%x * s; r%y = q%y * s
        r%z = q%z * s; r%w = q%w * s
    end function quat_scale

    pure function quat_negate(q) result(r)
        type(quat), intent(in) :: q
        type(quat) :: r
        r = quat_scale(q, -1.0_dp)
    end function quat_negate

    pure function quat_dot(a, b) result(d)
        type(quat), intent(in) :: a, b
        real(dp) :: d
        d = a%x * b%x + a%y * b%y + a%z * b%z + a%w * b%w
    end function quat_dot

    pure function quat_normalize(q) result(r)
        type(quat), intent(in) :: q
        type(quat) :: r
        real(dp) :: l
        l = sqrt(quat_dot(q, q))
        if (l > 1.0e-12_dp) then
            r = quat_scale(q, 1.0_dp / l)
        else
            r = quat_identity()
        end if
    end function quat_normalize

    pure function quat_conjugate(q) result(r)
        type(quat), intent(in) :: q
        type(quat) :: r
        r = quat_create(-q%x, -q%y, -q%z, q%w)
    end function quat_conjugate

    ! For a unit quaternion the inverse is the conjugate; the
    ! general form divides by |q|^2 (zero quaternion -> identity).
    pure function quat_inverse(q) result(r)
        type(quat), intent(in) :: q
        type(quat) :: r
        real(dp) :: n2
        n2 = quat_dot(q, q)
        if (n2 > 1.0e-24_dp) then
            r = quat_scale(quat_conjugate(q), 1.0_dp / n2)
        else
            r = quat_identity()
        end if
    end function quat_inverse

    ! Hamilton product: a (x) b applies b FIRST, then a (the same
    ! composition order as mat4_mult(a, b)).
    pure function quat_multiply(a, b) result(c)
        type(quat), intent(in) :: a, b
        type(quat) :: c
        c%x = a%w * b%x + a%x * b%w + a%y * b%z - a%z * b%y
        c%y = a%w * b%y - a%x * b%z + a%y * b%w + a%z * b%x
        c%z = a%w * b%z + a%x * b%y - a%y * b%x + a%z * b%w
        c%w = a%w * b%w - a%x * b%x - a%y * b%y - a%z * b%z
    end function quat_multiply

    pure function quat_from_axis_angle(axis, angle_deg) result(q)
        type(vec3), intent(in) :: axis
        real(dp), intent(in) :: angle_deg
        type(quat) :: q
        type(vec3) :: a
        real(dp) :: half, s
        a = vec3_normalize(axis)
        if (vec3_norm(a) <= 1.0e-12_dp) then
            q = quat_identity()
            return
        end if
        half = deg2rad(angle_deg) * 0.5_dp
        s = sin(half)
        q = quat_create(a%x * s, a%y * s, a%z * s, cos(half))
    end function quat_from_axis_angle

    ! Euler degrees, (x, y, z) = (pitch, yaw, roll), order
    ! R = Ry * Rx * Rz as in mat4_compose_trs: q = qy (x) qx (x) qz.
    pure function quat_from_euler(euler_deg) result(q)
        type(vec3), intent(in) :: euler_deg
        type(quat) :: q
        type(quat) :: qx, qy, qz
        qx = quat_from_axis_angle(vec3_create(1.0_dp, 0.0_dp, 0.0_dp), &
                                  euler_deg%x)
        qy = quat_from_axis_angle(vec3_create(0.0_dp, 1.0_dp, 0.0_dp), &
                                  euler_deg%y)
        qz = quat_from_axis_angle(vec3_create(0.0_dp, 0.0_dp, 1.0_dp), &
                                  euler_deg%z)
        q = quat_multiply(qy, quat_multiply(qx, qz))
    end function quat_from_euler

    pure function quat_to_mat3(q) result(r)
        type(quat), intent(in) :: q
        type(mat3) :: r
        type(quat) :: u
        real(dp) :: x, y, z, w
        u = quat_normalize(q)
        x = u%x; y = u%y; z = u%z; w = u%w
        r%m(1, 1) = 1.0_dp - 2.0_dp * (y * y + z * z)
        r%m(1, 2) = 2.0_dp * (x * y - z * w)
        r%m(1, 3) = 2.0_dp * (x * z + y * w)
        r%m(2, 1) = 2.0_dp * (x * y + z * w)
        r%m(2, 2) = 1.0_dp - 2.0_dp * (x * x + z * z)
        r%m(2, 3) = 2.0_dp * (y * z - x * w)
        r%m(3, 1) = 2.0_dp * (x * z - y * w)
        r%m(3, 2) = 2.0_dp * (y * z + x * w)
        r%m(3, 3) = 1.0_dp - 2.0_dp * (x * x + y * y)
    end function quat_to_mat3

    pure function quat_to_mat4(q) result(r)
        type(quat), intent(in) :: q
        type(mat4) :: r
        r = mat3_to_mat4(quat_to_mat3(q))
    end function quat_to_mat4

    ! Inverse of quat_from_euler; see the section header for the
    ! extraction formulas and the gimbal policy.
    pure function quat_to_euler(q) result(e)
        type(quat), intent(in) :: q
        type(vec3) :: e
        type(mat3) :: r
        real(dp) :: sx
        r = quat_to_mat3(q)
        sx = max(-1.0_dp, min(1.0_dp, -r%m(2, 3)))
        e%x = rad2deg(asin(sx))
        if (abs(sx) < 1.0_dp - 1.0e-12_dp) then
            e%y = rad2deg(atan2(r%m(1, 3), r%m(3, 3)))
            e%z = rad2deg(atan2(r%m(2, 1), r%m(2, 2)))
        else
            e%z = 0.0_dp
            if (sx >= 0.0_dp) then
                e%y = rad2deg(atan2(r%m(1, 2), r%m(1, 1)))
            else
                e%y = rad2deg(atan2(-r%m(1, 2), r%m(1, 1)))
            end if
        end if
    end function quat_to_euler

    ! Trace-based matrix -> quaternion with the standard stable
    ! branch on the largest diagonal (from the upper 3x3).
    pure function quat_from_mat3(m) result(q)
        type(mat3), intent(in) :: m
        type(quat) :: q
        real(dp) :: tr, s
        tr = m%m(1, 1) + m%m(2, 2) + m%m(3, 3)
        if (tr > 0.0_dp) then
            s = sqrt(tr + 1.0_dp) * 2.0_dp
            q%w = 0.25_dp * s
            q%x = (m%m(3, 2) - m%m(2, 3)) / s
            q%y = (m%m(1, 3) - m%m(3, 1)) / s
            q%z = (m%m(2, 1) - m%m(1, 2)) / s
        else if (m%m(1, 1) > m%m(2, 2) .and. m%m(1, 1) > m%m(3, 3)) then
            s = sqrt(1.0_dp + m%m(1, 1) - m%m(2, 2) - m%m(3, 3)) * 2.0_dp
            q%w = (m%m(3, 2) - m%m(2, 3)) / s
            q%x = 0.25_dp * s
            q%y = (m%m(1, 2) + m%m(2, 1)) / s
            q%z = (m%m(1, 3) + m%m(3, 1)) / s
        else if (m%m(2, 2) > m%m(3, 3)) then
            s = sqrt(1.0_dp + m%m(2, 2) - m%m(1, 1) - m%m(3, 3)) * 2.0_dp
            q%w = (m%m(1, 3) - m%m(3, 1)) / s
            q%x = (m%m(1, 2) + m%m(2, 1)) / s
            q%y = 0.25_dp * s
            q%z = (m%m(2, 3) + m%m(3, 2)) / s
        else
            s = sqrt(1.0_dp + m%m(3, 3) - m%m(1, 1) - m%m(2, 2)) * 2.0_dp
            q%w = (m%m(2, 1) - m%m(1, 2)) / s
            q%x = (m%m(1, 3) + m%m(3, 1)) / s
            q%y = (m%m(2, 3) + m%m(3, 2)) / s
            q%z = 0.25_dp * s
        end if
        q = quat_normalize(q)
    end function quat_from_mat3

    pure function quat_from_mat4(m) result(q)
        type(mat4), intent(in) :: m
        type(quat) :: q
        q = quat_from_mat3(mat3_from_mat4(m))
    end function quat_from_mat4

    ! Rotate v by q: v' = v + 2 * cross(u, cross(u, v) + w v),
    ! u = (x, y, z).  q is normalised first, so any non-zero scalar
    ! multiple of a unit quaternion gives the same rotation.
    pure function quat_rotate_vec3(q, v) result(r)
        type(quat), intent(in) :: q
        type(vec3), intent(in) :: v
        type(vec3) :: r
        type(quat) :: u
        type(vec3) :: uv, inner
        u = quat_normalize(q)
        uv = vec3_create(u%x, u%y, u%z)
        inner = vec3_add(vec3_cross(uv, v), vec3_scale(v, u%w))
        r = vec3_add(v, vec3_scale(vec3_cross(uv, inner), 2.0_dp))
    end function quat_rotate_vec3

    ! Spherical linear interpolation, SHORTEST PATH: when
    ! dot(q1, q2) < 0 the second quaternion is negated first (same
    ! rotation, shorter arc).  Near-parallel inputs (dot > 0.9995)
    ! fall back to normalised lerp.  t is clamped to [0, 1] and
    ! the result is normalised; the endpoints return the (unit)
    ! inputs themselves.
    pure function quat_slerp(q1, q2, t) result(r)
        type(quat), intent(in) :: q1, q2
        real(dp), intent(in) :: t
        type(quat) :: r
        type(quat) :: a, b
        real(dp) :: tt, d, theta, s, wa, wb
        tt = min(max(t, 0.0_dp), 1.0_dp)
        a = quat_normalize(q1)
        b = quat_normalize(q2)
        if (tt <= 0.0_dp) then
            r = a
            return
        end if
        if (tt >= 1.0_dp) then
            r = b
            return
        end if
        d = quat_dot(a, b)
        if (d < 0.0_dp) then
            b = quat_negate(b)
            d = -d
        end if
        if (d > 0.9995_dp) then
            r = quat_normalize(quat_add(a, quat_scale( &
                quat_sub(b, a), tt)))
        else
            theta = acos(min(d, 1.0_dp))
            s = sin(theta)
            wa = sin((1.0_dp - tt) * theta) / s
            wb = sin(tt * theta) / s
            r = quat_normalize(quat_add(quat_scale(a, wa), &
                                        quat_scale(b, wb)))
        end if
    end function quat_slerp

    ! ==================================================================
    ! Phase 5: general mat4 inverse
    ! ==================================================================

    ! Determinant of the 3x3 minor of m with row ri and column cj
    ! removed (private helper for mat4_inverse).
    pure function mat4_minor_det(m, ri, cj) result(d)
        type(mat4), intent(in) :: m
        integer, intent(in) :: ri, cj
        real(dp) :: d
        real(dp) :: a(3, 3)
        integer :: i, j, ii, jj
        ii = 0
        do i = 1, 4
            if (i == ri) cycle
            ii = ii + 1
            jj = 0
            do j = 1, 4
                if (j == cj) cycle
                jj = jj + 1
                a(ii, jj) = m%m(i, j)
            end do
        end do
        d = a(1, 1) * (a(2, 2) * a(3, 3) - a(2, 3) * a(3, 2)) &
          - a(1, 2) * (a(2, 1) * a(3, 3) - a(2, 3) * a(3, 1)) &
          + a(1, 3) * (a(2, 1) * a(3, 2) - a(2, 2) * a(3, 1))
    end function mat4_minor_det

    ! GENERAL 4x4 inverse (adjugate / determinant), valid for any
    ! invertible matrix -- unlike mat4_inverse_rigid, which assumes
    ! an orthonormal upper 3x3.  For rigid transforms the two agree
    ! to rounding.  Singular guard (see the section header):
    ! determinant exactly 0 -> ok = .false. and r = identity.
    ! Not pure: see the header note on the ok flag.
    function mat4_inverse(m, ok) result(r)
        type(mat4), intent(in) :: m
        logical, intent(out) :: ok
        type(mat4) :: r
        real(dp) :: cof(4, 4), det, inv_det
        integer :: i, j
        do i = 1, 4
            do j = 1, 4
                cof(i, j) = mat4_minor_det(m, i, j)
                if (mod(i + j, 2) == 1) cof(i, j) = -cof(i, j)
            end do
        end do
        det = m%m(1, 1) * cof(1, 1) + m%m(1, 2) * cof(1, 2) &
            + m%m(1, 3) * cof(1, 3) + m%m(1, 4) * cof(1, 4)
        if (abs(det) > 0.0_dp) then
            ok = .true.
        else
            ok = .false.
            r = mat4_identity()
            return
        end if
        inv_det = 1.0_dp / det
        do i = 1, 4
            do j = 1, 4
                r%m(i, j) = cof(j, i) * inv_det
            end do
        end do
    end function mat4_inverse

end module math_3d
