module material_3d
    use math_3d, only: dp
    implicit none
    private
    public :: Material
    public :: material_lambert, material_basic, material_phong
    public :: material_from_name, material_default, material_id_from_name

    type :: Material
        character(len=32) :: name = 'lambert'
        integer :: mode = 0            ! 0=lambert, 1=basic(unlit), 2=phong
        real(dp) :: color(3) = [1.0_dp, 1.0_dp, 1.0_dp]   ! 0..1 RGB
        logical :: use_tri_color = .true.
        real(dp) :: shininess = 32.0_dp
        real(dp) :: specular = 0.5_dp
    end type Material

contains

    pure function clamp01(x) result(r)
        real(dp), intent(in) :: x
        real(dp) :: r
        r = min(max(x, 0.0_dp), 1.0_dp)
    end function clamp01

    pure function clamp_rgb(rgb) result(r)
        real(dp), intent(in) :: rgb(3)
        real(dp) :: r(3)
        r(1) = clamp01(rgb(1))
        r(2) = clamp01(rgb(2))
        r(3) = clamp01(rgb(3))
    end function clamp_rgb

    pure function material_lambert(rgb, use_tri) result(m)
        real(dp), intent(in) :: rgb(3)
        logical, intent(in) :: use_tri
        type(Material) :: m
        m%name = 'lambert'
        m%mode = 0
        m%color = clamp_rgb(rgb)
        m%use_tri_color = use_tri
        m%shininess = 32.0_dp
        m%specular = 0.5_dp
    end function material_lambert

    pure function material_basic(rgb) result(m)
        real(dp), intent(in) :: rgb(3)
        type(Material) :: m
        m%name = 'basic'
        m%mode = 1
        m%color = clamp_rgb(rgb)
        m%use_tri_color = .false.
        m%shininess = 32.0_dp
        m%specular = 0.5_dp
    end function material_basic

    pure function material_phong(rgb, shininess) result(m)
        real(dp), intent(in) :: rgb(3)
        real(dp), intent(in) :: shininess
        type(Material) :: m
        m%name = 'phong'
        m%mode = 2
        m%color = clamp_rgb(rgb)
        m%use_tri_color = .false.
        m%shininess = shininess
        m%specular = 0.5_dp
    end function material_phong

    pure function material_from_name(name, rgb, use_tri) result(m)
        character(len=*), intent(in) :: name
        real(dp), intent(in) :: rgb(3)
        logical, intent(in) :: use_tri
        type(Material) :: m
        select case (trim(name))
        case ('basic')
            m = material_basic(rgb)
            m%use_tri_color = use_tri
        case ('phong')
            m = material_phong(rgb, 32.0_dp)
            m%use_tri_color = use_tri
        case default
            m = material_lambert(rgb, use_tri)
        end select
    end function material_from_name

    pure function material_default() result(m)
        type(Material) :: m
        m = material_lambert([1.0_dp, 1.0_dp, 1.0_dp], .true.)
    end function material_default

    pure function material_id_from_name(name) result(id)
        character(len=*), intent(in) :: name
        integer :: id
        select case (trim(name))
        case ('basic')
            id = 1
        case ('phong')
            id = 2
        case default
            id = 0
        end select
    end function material_id_from_name

end module material_3d
