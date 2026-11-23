! obj_loader.f90 -- Wavefront OBJ reader (Forge3D v3.0 Phase 1, G2).
!
! Public API:
!   load_obj(path, mesh_out, ok)
!       The original entry point, unchanged: fills a mesh_3d Mesh.
!   load_obj_ex(path, mesh_out, ok, info)
!       Additive extended entry point.  In addition to the mesh it
!       returns an ObjInfo with everything the base Mesh/Triangle
!       types cannot carry: the .mtl material table (Kd/Ka/Ks/
!       map_Kd), named group/object triangle ranges, and per-corner
!       UVs.  Per-vertex normals DO fit the base types and are stored
!       in Triangle%vn (smooth shading) by both entry points.
!
! Supported: v / vt / vn, faces in all forms (v, v/vt, v//vn,
! v/vt/vn) with positive or negative (relative) indices, fan
! triangulation of n-gons, g / o groups, mtllib + usemtl with Kd,
! Ka, Ks and map_Kd parsed from the referenced .mtl file(s).
! Missing vt/vn never corrupts positions: absent UVs read as (0,0)
! in the ObjInfo table and absent normals fall back to the computed
! flat face normal.  A face corner whose position index is invalid
! invalidates only that face, as before.
module obj_loader
    use math_3d
    use mesh_3d
    implicit none
    private
    public :: load_obj, load_obj_ex
    public :: ObjMaterial, ObjGroupRange, ObjInfo, obj_free_info

    type :: ObjMaterial
        character(len=64) :: name = ''
        real(dp) :: kd(3) = [1.0_dp, 1.0_dp, 1.0_dp]
        real(dp) :: ka(3) = [0.0_dp, 0.0_dp, 0.0_dp]
        real(dp) :: ks(3) = [0.0_dp, 0.0_dp, 0.0_dp]
        logical :: has_kd = .false.
        character(len=256) :: map_kd = ''
    end type ObjMaterial

    type :: ObjGroupRange
        character(len=64) :: name = ''
        character(len=64) :: material_name = ''
        integer :: tri_start = 0   ! 1-based first triangle
        integer :: tri_count = 0
    end type ObjGroupRange

    type :: ObjInfo
        type(ObjMaterial), allocatable :: materials(:)
        integer :: n_materials = 0
        type(ObjGroupRange), allocatable :: groups(:)
        integer :: n_groups = 0
        ! Per-triangle-corner UVs: tri_uv(t, corner, 1:2) = (u, v);
        ! (0,0) where the face supplied no vt.  has_uv is .true. when
        ! at least one face corner in the file carried a vt index.
        real(dp), allocatable :: tri_uv(:, :, :)
        logical :: has_uv = .false.
        logical :: has_vn = .false.
    end type ObjInfo

contains

    subroutine obj_free_info(info)
        type(ObjInfo), intent(inout) :: info
        if (allocated(info%materials)) deallocate(info%materials)
        if (allocated(info%groups)) deallocate(info%groups)
        if (allocated(info%tri_uv)) deallocate(info%tri_uv)
        info%n_materials = 0
        info%n_groups = 0
        info%has_uv = .false.
        info%has_vn = .false.
    end subroutine obj_free_info

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

    ! Resolve one OBJ index field: positive = absolute, negative =
    ! relative to count (OBJ convention).  0 when empty/invalid.
    function resolve_index(raw, count) result(idx)
        integer, intent(in) :: raw, count
        integer :: idx
        if (raw > 0) then
            idx = raw
        else if (raw < 0) then
            idx = count + raw + 1
        else
            idx = 0
        end if
        if (idx < 1 .or. idx > count) idx = 0
    end function resolve_index

    ! Parse one face corner token "v", "v/vt", "v//vn", "v/vt/vn"
    ! into resolved 1-based indices (0 = absent/invalid per field).
    subroutine parse_corner_full(tok, nv, nvt, nvn, iv, ivt, ivn)
        character(len=*), intent(in) :: tok
        integer, intent(in) :: nv, nvt, nvn
        integer, intent(out) :: iv, ivt, ivn
        integer :: s1, s2, ios, raw
        iv = 0; ivt = 0; ivn = 0
        s1 = index(tok, '/')
        if (s1 == 0) then
            read(tok, *, iostat=ios) raw
            if (ios == 0) iv = resolve_index(raw, nv)
            return
        end if
        if (s1 > 1) then
            read(tok(1:s1 - 1), *, iostat=ios) raw
            if (ios == 0) iv = resolve_index(raw, nv)
        end if
        s2 = index(tok(s1 + 1:), '/')
        if (s2 == 0) then
            ! v/vt form
            if (s1 < len_trim(tok)) then
                read(tok(s1 + 1:), *, iostat=ios) raw
                if (ios == 0) ivt = resolve_index(raw, nvt)
            end if
        else
            s2 = s1 + s2  ! absolute position of second slash
            if (s2 > s1 + 1) then
                read(tok(s1 + 1:s2 - 1), *, iostat=ios) raw
                if (ios == 0) ivt = resolve_index(raw, nvt)
            end if
            if (s2 < len_trim(tok)) then
                read(tok(s2 + 1:), *, iostat=ios) raw
                if (ios == 0) ivn = resolve_index(raw, nvn)
            end if
        end if
    end subroutine parse_corner_full

    function find_material(info, name) result(idx)
        type(ObjInfo), intent(in) :: info
        character(len=*), intent(in) :: name
        integer :: idx, i
        idx = 0
        do i = 1, info%n_materials
            if (trim(info%materials(i)%name) == trim(name)) then
                idx = i
                return
            end if
        end do
    end function find_material

    subroutine add_material(info, mat)
        type(ObjInfo), intent(inout) :: info
        type(ObjMaterial), intent(in) :: mat
        type(ObjMaterial), allocatable :: tmp(:)
        integer :: cap, new_cap
        cap = 0
        if (allocated(info%materials)) cap = size(info%materials)
        if (info%n_materials >= cap) then
            new_cap = max(8, 2 * cap)
            allocate(tmp(new_cap))
            if (info%n_materials > 0) &
                tmp(1:info%n_materials) = info%materials(1:info%n_materials)
            if (allocated(info%materials)) deallocate(info%materials)
            call move_alloc(tmp, info%materials)
        end if
        info%n_materials = info%n_materials + 1
        info%materials(info%n_materials) = mat
    end subroutine add_material

    subroutine add_group(info, grp)
        type(ObjInfo), intent(inout) :: info
        type(ObjGroupRange), intent(in) :: grp
        type(ObjGroupRange), allocatable :: tmp(:)
        integer :: cap, new_cap
        if (grp%tri_count <= 0) return
        cap = 0
        if (allocated(info%groups)) cap = size(info%groups)
        if (info%n_groups >= cap) then
            new_cap = max(8, 2 * cap)
            allocate(tmp(new_cap))
            if (info%n_groups > 0) &
                tmp(1:info%n_groups) = info%groups(1:info%n_groups)
            if (allocated(info%groups)) deallocate(info%groups)
            call move_alloc(tmp, info%groups)
        end if
        info%n_groups = info%n_groups + 1
        info%groups(info%n_groups) = grp
    end subroutine add_group

    ! Parse one .mtl file, appending its materials to info.
    subroutine load_mtl(path, info)
        character(len=*), intent(in) :: path
        type(ObjInfo), intent(inout) :: info
        integer, parameter :: MAX_TOK = 64, LINE_LEN = 4096
        character(len=LINE_LEN) :: line
        integer :: starts(MAX_TOK), ends(MAX_TOK), ntok
        integer :: u, ios, hash, cur
        logical :: exists
        type(ObjMaterial) :: mat
        real(dp) :: r, g, b

        inquire(file=trim(path), exist=exists)
        if (.not. exists) return
        open(newunit=u, file=trim(path), status='old', action='read', &
             iostat=ios)
        if (ios /= 0) return
        cur = 0
        do
            read(u, '(A)', iostat=ios) line
            if (ios /= 0) exit
            hash = index(line, '#')
            if (hash > 0) line(hash:) = ' '
            if (len_trim(line) == 0) cycle
            call split_tokens(line, starts, ends, ntok)
            if (ntok == 0) cycle
            select case (line(starts(1):ends(1)))
            case ('newmtl')
                if (cur > 0) call add_material(info, mat)
                mat = ObjMaterial()
                if (ntok >= 2) mat%name = line(starts(2):ends(ntok))
                cur = cur + 1
            case ('Kd', 'Ka', 'Ks')
                if (cur == 0 .or. ntok < 4) cycle
                read(line(starts(2):ends(2)), *, iostat=ios) r
                if (ios /= 0) cycle
                read(line(starts(3):ends(3)), *, iostat=ios) g
                if (ios /= 0) cycle
                read(line(starts(4):ends(4)), *, iostat=ios) b
                if (ios /= 0) cycle
                select case (line(starts(1):ends(1)))
                case ('Kd')
                    mat%kd = [r, g, b]
                    mat%has_kd = .true.
                case ('Ka')
                    mat%ka = [r, g, b]
                case ('Ks')
                    mat%ks = [r, g, b]
                end select
            case ('map_Kd')
                if (cur == 0 .or. ntok < 2) cycle
                ! Filename is the last token (options may precede it).
                mat%map_kd = line(starts(ntok):ends(ntok))
            case default
                cycle
            end select
        end do
        close(u)
        if (cur > 0) call add_material(info, mat)
    end subroutine load_mtl

    subroutine load_obj(path, mesh_out, ok)
        character(len=*), intent(in) :: path
        type(Mesh), intent(inout) :: mesh_out
        logical, intent(out) :: ok
        type(ObjInfo) :: info
        call load_obj_ex(path, mesh_out, ok, info)
        call obj_free_info(info)
    end subroutine load_obj

    subroutine load_obj_ex(path, mesh_out, ok, info)
        character(len=*), intent(in) :: path
        type(Mesh), intent(inout) :: mesh_out
        logical, intent(out) :: ok
        type(ObjInfo), intent(out) :: info

        integer, parameter :: MAX_TOK = 512, LINE_LEN = 4096
        character(len=LINE_LEN) :: line
        integer :: starts(MAX_TOK), ends(MAX_TOK), ntok
        integer :: u, ios, hash, i, k, ncorner, slash
        logical :: exists, valid
        real(dp) :: x, y, z

        type(vec3), allocatable :: verts(:), vtmp3(:)
        integer :: nverts, vcap
        real(dp), allocatable :: uvs(:, :), uvtmp(:, :)
        integer :: nuvs, ucap
        type(vec3), allocatable :: norms(:), ntmp(:)
        integer :: nnorms, ncap
        type(Triangle), allocatable :: tris(:), ttmp(:)
        integer :: ntris, tcap
        real(dp), allocatable :: triuv(:, :, :), tuvtmp(:, :, :)
        integer :: civ(MAX_TOK), civt(MAX_TOK), civn(MAX_TOK)
        type(Triangle) :: tri
        character(len=512) :: dir, mtlpath
        character(len=64) :: cur_group, cur_mtl
        type(ObjGroupRange) :: grp
        integer :: grp_start, mat_idx
        logical :: grp_open

        ok = .false.
        info = ObjInfo()
        if (allocated(mesh_out%triangles)) deallocate(mesh_out%triangles)
        mesh_out%num_triangles = 0
        allocate(mesh_out%triangles(0))

        nverts = 0; vcap = 0
        nuvs = 0; ucap = 0
        nnorms = 0; ncap = 0
        ntris = 0; tcap = 0
        cur_group = 'default'
        cur_mtl = ''
        grp_start = 1
        grp_open = .false.

        dir = ''
        slash = index(trim(path), '/', back=.true.)
        if (slash > 1) dir = path(1:slash - 1)

        inquire(file=trim(path), exist=exists)
        if (.not. exists) return
        open(newunit=u, file=trim(path), status='old', action='read', &
             iostat=ios)
        if (ios /= 0) return

        do
            read(u, '(A)', iostat=ios) line
            if (ios /= 0) exit
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
                        allocate(vtmp3(vcap * 2))
                        if (nverts > 0) vtmp3(1:nverts) = verts(1:nverts)
                        call move_alloc(vtmp3, verts)
                        vcap = vcap * 2
                    end if
                end if
                nverts = nverts + 1
                verts(nverts) = vec3_create(x, y, z)
            case ('vt')
                if (ntok < 3) cycle
                read(line(starts(2):ends(2)), *, iostat=ios) x
                if (ios /= 0) cycle
                read(line(starts(3):ends(3)), *, iostat=ios) y
                if (ios /= 0) cycle
                if (nuvs >= ucap) then
                    if (ucap == 0) then
                        ucap = 1024
                        allocate(uvs(2, ucap))
                    else
                        allocate(uvtmp(2, ucap * 2))
                        if (nuvs > 0) uvtmp(:, 1:nuvs) = uvs(:, 1:nuvs)
                        call move_alloc(uvtmp, uvs)
                        ucap = ucap * 2
                    end if
                end if
                nuvs = nuvs + 1
                uvs(1, nuvs) = x
                uvs(2, nuvs) = y
            case ('vn')
                if (ntok < 4) cycle
                read(line(starts(2):ends(2)), *, iostat=ios) x
                if (ios /= 0) cycle
                read(line(starts(3):ends(3)), *, iostat=ios) y
                if (ios /= 0) cycle
                read(line(starts(4):ends(4)), *, iostat=ios) z
                if (ios /= 0) cycle
                if (nnorms >= ncap) then
                    if (ncap == 0) then
                        ncap = 1024
                        allocate(norms(ncap))
                    else
                        allocate(ntmp(ncap * 2))
                        if (nnorms > 0) ntmp(1:nnorms) = norms(1:nnorms)
                        call move_alloc(ntmp, norms)
                        ncap = ncap * 2
                    end if
                end if
                nnorms = nnorms + 1
                norms(nnorms) = vec3_create(x, y, z)
            case ('mtllib')
                if (ntok < 2) cycle
                if (len_trim(dir) > 0) then
                    mtlpath = trim(dir) // '/' // line(starts(2):ends(ntok))
                else
                    mtlpath = line(starts(2):ends(ntok))
                end if
                call load_mtl(trim(mtlpath), info)
            case ('usemtl')
                ! Close the open group range before switching material.
                if (grp_open .and. ntris >= grp_start) then
                    grp%name = cur_group
                    grp%material_name = cur_mtl
                    grp%tri_start = grp_start
                    grp%tri_count = ntris - grp_start + 1
                    call add_group(info, grp)
                end if
                grp_start = ntris + 1
                grp_open = .true.
                if (ntok >= 2) then
                    cur_mtl = line(starts(2):ends(ntok))
                else
                    cur_mtl = ''
                end if
            case ('g', 'o')
                if (grp_open .and. ntris >= grp_start) then
                    grp%name = cur_group
                    grp%material_name = cur_mtl
                    grp%tri_start = grp_start
                    grp%tri_count = ntris - grp_start + 1
                    call add_group(info, grp)
                end if
                grp_start = ntris + 1
                grp_open = .true.
                if (ntok >= 2) then
                    cur_group = line(starts(2):ends(ntok))
                else
                    cur_group = 'default'
                end if
            case ('f')
                if (ntok < 4) cycle
                ncorner = 0
                valid = .true.
                do i = 2, ntok
                    call parse_corner_full(line(starts(i):ends(i)), &
                        nverts, nuvs, nnorms, civ(i - 1), civt(i - 1), &
                        civn(i - 1))
                    if (civ(i - 1) == 0) then
                        valid = .false.
                        exit
                    end if
                    ncorner = ncorner + 1
                end do
                if (.not. valid .or. ncorner < 3) cycle
                if (.not. grp_open) then
                    grp_open = .true.
                    grp_start = ntris + 1
                end if
                mat_idx = 0
                if (len_trim(cur_mtl) > 0) &
                    mat_idx = find_material(info, cur_mtl)
                ! Fan triangulation: (c1, ck, ck+1), k = 2..ncorner-1
                do k = 2, ncorner - 1
                    if (ntris >= tcap) then
                        if (tcap == 0) then
                            tcap = 1024
                            allocate(tris(tcap))
                            allocate(triuv(tcap, 3, 2))
                        else
                            allocate(ttmp(tcap * 2))
                            allocate(tuvtmp(tcap * 2, 3, 2))
                            if (ntris > 0) then
                                ttmp(1:ntris) = tris(1:ntris)
                                tuvtmp(1:ntris, :, :) = triuv(1:ntris, :, :)
                            end if
                            call move_alloc(ttmp, tris)
                            call move_alloc(tuvtmp, triuv)
                            tcap = tcap * 2
                        end if
                    end if
                    block
                        integer :: cc(3), cct(3), ccn(3), j
                        cc = [civ(1), civ(k), civ(k + 1)]
                        cct = [civt(1), civt(k), civt(k + 1)]
                        ccn = [civn(1), civn(k), civn(k + 1)]
                        do j = 1, 3
                            tri%v(j) = verts(cc(j))
                            if (cct(j) > 0) then
                                triuv(ntris + 1, j, 1) = uvs(1, cct(j))
                                triuv(ntris + 1, j, 2) = uvs(2, cct(j))
                                info%has_uv = .true.
                            else
                                triuv(ntris + 1, j, 1) = 0.0_dp
                                triuv(ntris + 1, j, 2) = 0.0_dp
                            end if
                            if (ccn(j) > 0) then
                                tri%vn(j) = vec3_normalize(norms(ccn(j)))
                                info%has_vn = .true.
                            end if
                        end do
                        tri%normal = compute_triangle_normal( &
                            tri%v(1), tri%v(2), tri%v(3))
                        if (ccn(1) > 0 .and. ccn(2) > 0 .and. &
                            ccn(3) > 0) then
                            tri%smooth = .true.
                        else
                            tri%smooth = .false.
                            tri%vn = [tri%normal, tri%normal, tri%normal]
                        end if
                        tri%color = [255, 255, 255]
                        if (mat_idx > 0) then
                            if (info%materials(mat_idx)%has_kd) then
                                tri%color = nint(255.0_dp * &
                                    min(max(info%materials(mat_idx)%kd, &
                                            0.0_dp), 1.0_dp))
                            end if
                        end if
                        tri%material_id = mat_idx
                    end block
                    ntris = ntris + 1
                    tris(ntris) = tri
                end do
            case default
                cycle
            end select
        end do
        close(u)

        if (grp_open .and. ntris >= grp_start) then
            grp%name = cur_group
            grp%material_name = cur_mtl
            grp%tri_start = grp_start
            grp%tri_count = ntris - grp_start + 1
            call add_group(info, grp)
        end if

        if (ntris <= 0) then
            if (allocated(verts)) deallocate(verts)
            if (allocated(uvs)) deallocate(uvs)
            if (allocated(norms)) deallocate(norms)
            if (allocated(tris)) deallocate(tris)
            if (allocated(triuv)) deallocate(triuv)
            return
        end if

        deallocate(mesh_out%triangles)
        allocate(mesh_out%triangles(ntris))
        mesh_out%triangles(1:ntris) = tris(1:ntris)
        mesh_out%num_triangles = ntris
        allocate(info%tri_uv(ntris, 3, 2))
        info%tri_uv = triuv(1:ntris, :, :)
        ok = .true.

        if (allocated(verts)) deallocate(verts)
        if (allocated(uvs)) deallocate(uvs)
        if (allocated(norms)) deallocate(norms)
        if (allocated(tris)) deallocate(tris)
        if (allocated(triuv)) deallocate(triuv)
    end subroutine load_obj_ex

end module obj_loader
