module math_3d
    use, intrinsic :: iso_fortran_env, only: dp => real64
    implicit none
    private
    public :: dp, vec3, mat4, &
              vec3_create, vec3_add, vec3_sub, vec3_scale, vec3_dot, vec3_cross, vec3_norm, vec3_normalize, &
              mat4_identity, mat4_mult, mat4_translation, mat4_scale, &
              mat4_rotate_x, mat4_rotate_y, mat4_rotate_z, &
              mat4_perspective, mat4_look_at, mat4_transform_vec3

    real(dp), parameter, public :: PI = 3.14159265358979323846_dp

    type :: vec3
        real(dp) :: x = 0.0_dp
        real(dp) :: y = 0.0_dp
        real(dp) :: z = 0.0_dp
    end type vec3

    type :: mat4
        real(dp) :: m(4, 4) = 0.0_dp
    end type mat4

contains

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
        type(vec3) :: f, r, u

        f = vec3_normalize(vec3_sub(target, eye))
        r = vec3_normalize(vec3_cross(f, up))
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

end module math_3d
