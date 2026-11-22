module obj_loader
    use math_3d
    use mesh_3d
    implicit none
    private
    public :: load_obj

contains

    ! Split `line` on spaces/tabs into token spans (1-based start/end).
    subroutine split_tokens(line, starts, ends, ntok)
        character(len=*), intent(in) :: line
        integer, intent(out) :: starts(:), ends(:), ntok
        integer :: i, n, max_tok
        logical :: in_tok

        n = len_trim(line)
        max_tok = size(starts)
        ntok = 0
        in_tok = .false.
        do i = 1, n
            if (line(i:i) == ' ' .or. line(i:i) == char(9)) then
                if (in_tok) then
                    ends(ntok) = i - 1
                    in_tok = .false.
                end if
            else
                if (.not. in_tok) then
                    if (ntok >= max_tok) exit
                    ntok = ntok + 1
                    starts(ntok) = i
                    in_tok = .true.
                end if
            end if
        end do
        if (in_tok) ends(ntok) = n
    end subroutine split_tokens

    ! Vertex index from a face corner token: "i", "i/j", "i//k", "i/j/k".
    ! Negative i is relative to the current vertex count (OBJ convention).
    ! Returns 0 on failure / out of range.
    function parse_corner(tok, nverts) result(idx)
        character(len=*), intent(in) :: tok
        integer, intent(in) :: nverts
        integer :: idx, slash, ios, raw

        slash = index(tok, '/')
        if (slash == 0) then
            read(tok, *, iostat=ios) raw
        else if (slash > 1) then
            read(tok(1:slash-1), *, iostat=ios) raw
        else
            ios = 1
            raw = 0
        end if
        if (ios /= 0) then
            idx = 0
            return
        end if
        if (raw > 0) then
            idx = raw
        else if (raw < 0) then
            idx = nverts + raw + 1
        else
            idx = 0
        end if
        if (idx < 1 .or. idx > nverts) idx = 0
    end function parse_corner

    subroutine load_obj(path, mesh_out, ok)
        character(len=*), intent(in) :: path
        type(Mesh), intent(inout) :: mesh_out
        logical, intent(out) :: ok

        integer, parameter :: MAX_TOK = 512, LINE_LEN = 4096
        character(len=LINE_LEN) :: line
        integer :: starts(MAX_TOK), ends(MAX_TOK), ntok
        integer :: u, ios, hash, i, k, ncorner
        integer :: corners(MAX_TOK)
        logical :: exists, valid
        real(dp) :: x, y, z

        type(vec3), allocatable :: verts(:), vtmp(:)
        integer :: nverts, vcap
        type(Triangle), allocatable :: tris(:), ttmp(:)
        integer :: ntris, tcap
        type(Triangle) :: tri

        ok = .false.
        if (allocated(mesh_out%triangles)) deallocate(mesh_out%triangles)
        mesh_out%num_triangles = 0
        allocate(mesh_out%triangles(0))

        nverts = 0; vcap = 0
        ntris = 0; tcap = 0

        inquire(file=trim(path), exist=exists)
        if (.not. exists) return
        open(newunit=u, file=trim(path), status='old', action='read', iostat=ios)
        if (ios /= 0) return

        do
            read(u, '(A)', iostat=ios) line
            if (ios /= 0) exit

            ! Strip '#' comments (whole-line or trailing).
            hash = index(line, '#')
            if (hash > 0) line(hash:) = ' '
            if (len_trim(line) == 0) cycle

            call split_tokens(line, starts, ends, ntok)
            if (ntok == 0) cycle

            select case (line(starts(1):ends(1)))
            case ('v')
                if (ntok < 4) cycle
                read(line(starts(2):ends(2)), *, iostat=ios) x
                if (ios /= 0) cycle
                read(line(starts(3):ends(3)), *, iostat=ios) y
                if (ios /= 0) cycle
                read(line(starts(4):ends(4)), *, iostat=ios) z
                if (ios /= 0) cycle
                if (nverts >= vcap) then
                    if (vcap == 0) then
                        vcap = 1024
                        allocate(verts(vcap))
                    else
                        allocate(vtmp(vcap * 2))
                        if (nverts > 0) vtmp(1:nverts) = verts(1:nverts)
                        call move_alloc(vtmp, verts)
                        vcap = vcap * 2
                    end if
                end if
                nverts = nverts + 1
                verts(nverts) = vec3_create(x, y, z)

            case ('f')
                if (ntok < 4) cycle  ! need at least 3 corners
                ncorner = 0
                valid = .true.
                do i = 2, ntok
                    k = parse_corner(line(starts(i):ends(i)), nverts)
                    if (k == 0) then
                        valid = .false.
                        exit
                    end if
                    ncorner = ncorner + 1
                    corners(ncorner) = k
                end do
                if (.not. valid .or. ncorner < 3) cycle
                ! Fan triangulation: (c1, ck, ck+1) for k = 2 .. ncorner-1
                do k = 2, ncorner - 1
                    if (ntris >= tcap) then
                        if (tcap == 0) then
                            tcap = 1024
                            allocate(tris(tcap))
                        else
                            allocate(ttmp(tcap * 2))
                            if (ntris > 0) ttmp(1:ntris) = tris(1:ntris)
                            call move_alloc(ttmp, tris)
                            tcap = tcap * 2
                        end if
                    end if
                    tri%v(1) = verts(corners(1))
                    tri%v(2) = verts(corners(k))
                    tri%v(3) = verts(corners(k + 1))
                    tri%normal = compute_triangle_normal(tri%v(1), tri%v(2), tri%v(3))
                    tri%color = [255, 255, 255]
                    tri%material_id = 0
                    ntris = ntris + 1
                    tris(ntris) = tri
                end do

            case default
                ! vt, vn, mtllib, usemtl, o, g, s and anything else: ignore.
                cycle
            end select
        end do
        close(u)

        if (ntris <= 0) then
            if (allocated(verts)) deallocate(verts)
            if (allocated(tris)) deallocate(tris)
            return  ! ok stays .false., mesh_out already has 0 triangles
        end if

        deallocate(mesh_out%triangles)
        allocate(mesh_out%triangles(ntris))
        mesh_out%triangles(1:ntris) = tris(1:ntris)
        mesh_out%num_triangles = ntris
        ok = .true.

        if (allocated(verts)) deallocate(verts)
        if (allocated(tris)) deallocate(tris)
    end subroutine load_obj

end module obj_loader
