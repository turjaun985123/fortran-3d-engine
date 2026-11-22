module mesh_3d
    use math_3d
    implicit none
    private
    public :: Triangle, Mesh, create_cube, compute_triangle_normal, export_mesh_json, export_mesh_obj

    type :: Triangle
        type(vec3) :: v(3) = [vec3(0.0_dp, 0.0_dp, 0.0_dp), &
                              vec3(0.0_dp, 0.0_dp, 0.0_dp), &
                              vec3(0.0_dp, 0.0_dp, 0.0_dp)]
        type(vec3) :: normal = vec3(0.0_dp, 0.0_dp, 0.0_dp)
        integer :: color(3) = [255, 255, 255]
    end type Triangle

    type :: Mesh
        integer :: num_triangles
        type(Triangle), allocatable :: triangles(:)
    end type Mesh

contains

    pure function compute_triangle_normal(v1, v2, v3) result(n)
        type(vec3), intent(in) :: v1, v2, v3
        type(vec3) :: n
        type(vec3) :: edge1, edge2
        edge1 = vec3_sub(v2, v1)
        edge2 = vec3_sub(v3, v1)
        n = vec3_normalize(vec3_cross(edge1, edge2))
    end function compute_triangle_normal

    subroutine create_cube(m, size)
        type(Mesh), intent(inout) :: m
        real(dp), intent(in) :: size
        real(dp) :: h
        type(vec3) :: p(8)
        integer :: i

        if (allocated(m%triangles)) deallocate(m%triangles)

        h = size * 0.5_dp

        ! Define 8 vertices of a box centered at origin
        p(1) = vec3_create(-h, -h, -h)
        p(2) = vec3_create( h, -h, -h)
        p(3) = vec3_create( h,  h, -h)
        p(4) = vec3_create(-h,  h, -h)
        p(5) = vec3_create(-h, -h,  h)
        p(6) = vec3_create( h, -h,  h)
        p(7) = vec3_create( h,  h,  h)
        p(8) = vec3_create(-h,  h,  h)

        m%num_triangles = 12
        allocate(m%triangles(12))

        ! South face (Z = -h)
        m%triangles(1)%v = [p(1), p(3), p(2)]
        m%triangles(2)%v = [p(1), p(4), p(3)]
        ! East face (X = +h)
        m%triangles(3)%v = [p(2), p(7), p(6)]
        m%triangles(4)%v = [p(2), p(3), p(7)]
        ! North face (Z = +h)
        m%triangles(5)%v = [p(6), p(8), p(5)]
        m%triangles(6)%v = [p(6), p(7), p(8)]
        ! West face (X = -h)
        m%triangles(7)%v = [p(5), p(4), p(1)]
        m%triangles(8)%v = [p(5), p(8), p(4)]
        ! Top face (Y = +h)
        m%triangles(9)%v = [p(4), p(7), p(3)]
        m%triangles(10)%v = [p(4), p(8), p(7)]
        ! Bottom face (Y = -h)
        m%triangles(11)%v = [p(5), p(2), p(6)]
        m%triangles(12)%v = [p(5), p(1), p(2)]

        ! Assign colors and calculate normals
        do i = 1, 12
            m%triangles(i)%normal = compute_triangle_normal( &
                m%triangles(i)%v(1), m%triangles(i)%v(2), m%triangles(i)%v(3))
            
            ! Color faces uniquely for visual distinction
            select case (i)
            case (1, 2)
                m%triangles(i)%color = [220, 60, 60]   ! Red
            case (3, 4)
                m%triangles(i)%color = [60, 220, 60]   ! Green
            case (5, 6)
                m%triangles(i)%color = [60, 100, 240]  ! Blue
            case (7, 8)
                m%triangles(i)%color = [240, 220, 50]  ! Yellow
            case (9, 10)
                m%triangles(i)%color = [200, 80, 220]  ! Magenta
            case default
                m%triangles(i)%color = [60, 220, 220]  ! Cyan
            end select
        end do
    end subroutine create_cube

    subroutine export_mesh_json(m, filename)
        type(Mesh), intent(in) :: m
        character(len=*), intent(in) :: filename
        integer :: u, i

        open(newunit=u, file=filename, status='replace', action='write')
        write(u, '(A)') '{'
        write(u, '(A)') '  "triangles": ['
        do i = 1, m%num_triangles
            write(u, '(A,I0,A)') '    {"id": ', i, ','
            write(u, '(A,F8.3,A,F8.3,A,F8.3,A,F8.3,A,F8.3,A,F8.3,A,F8.3,A,F8.3,A,F8.3,A)') &
                '     "v": [[', &
                m%triangles(i)%v(1)%x, ',', m%triangles(i)%v(1)%y, ',', m%triangles(i)%v(1)%z, '],[', &
                m%triangles(i)%v(2)%x, ',', m%triangles(i)%v(2)%y, ',', m%triangles(i)%v(2)%z, '],[', &
                m%triangles(i)%v(3)%x, ',', m%triangles(i)%v(3)%y, ',', m%triangles(i)%v(3)%z, ']],'
            write(u, '(A,I3,A,I3,A,I3,A)') &
                '     "color": [', &
                m%triangles(i)%color(1), ',', m%triangles(i)%color(2), ',', m%triangles(i)%color(3), ']}'
            if (i < m%num_triangles) then
                write(u, '(A)') ','
            else
                write(u, '(A)') ''
            end if
        end do
        write(u, '(A)') '  ]'
        write(u, '(A)') '}'
        close(u)
    end subroutine export_mesh_json

    subroutine export_mesh_obj(m, filename)
        type(Mesh), intent(in) :: m
        character(len=*), intent(in) :: filename
        integer :: u, i

        open(newunit=u, file=filename, status='replace', action='write')
        write(u, '(A)') '# Fortran 3D Engine OBJ Export'
        do i = 1, m%num_triangles
            write(u, '(A,3(1X,F9.4))') 'v', m%triangles(i)%v(1)%x, m%triangles(i)%v(1)%y, m%triangles(i)%v(1)%z
            write(u, '(A,3(1X,F9.4))') 'v', m%triangles(i)%v(2)%x, m%triangles(i)%v(2)%y, m%triangles(i)%v(2)%z
            write(u, '(A,3(1X,F9.4))') 'v', m%triangles(i)%v(3)%x, m%triangles(i)%v(3)%y, m%triangles(i)%v(3)%z
        end do
        do i = 1, m%num_triangles
            write(u, '(A,3(1X,I0))') 'f', (i-1)*3+1, (i-1)*3+2, (i-1)*3+3
        end do
        close(u)
    end subroutine export_mesh_obj

end module mesh_3d
