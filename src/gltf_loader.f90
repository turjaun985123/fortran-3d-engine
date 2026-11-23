! gltf_loader.f90 -- glTF 2.0 reader (Forge3D v3.0 Phase 1, G2).
!
! Public API:
!   load_gltf(path, mesh, ok)      -- original entry point, unchanged
!   load_gltf_ex(path, mesh, ok, info)
!       Additive extended entry point returning a GltfInfo with what
!       the base Mesh/Triangle types cannot carry: per-corner UVs and
!       tangents, and the material table (baseColorFactor,
!       baseColorTexture URI/index, metallic/roughness factors).
!       Per-vertex normals DO fit the base types and are stored in
!       Triangle%vn (smooth) by both entry points.
!
! Supported (glTF 2.0):
!   * .gltf (JSON parsed with the shared json_reader_3d parser) with
!     external .bin buffers and data: URI (base64) buffers, and .glb
!     binary containers (header + JSON chunk + BIN chunk).
!   * Scene graph: scenes/nodes walked recursively; node hierarchy
!     transforms (translation/rotation/scale and explicit matrix)
!     applied to positions and normals.
!   * Every mesh and every primitive (mode 4 / absent = triangles):
!     POSITION (required), NORMAL, TEXCOORD_0, TANGENT (read when
!     present), indices (sequential when absent), primitive material.
!   * Accessors: float VEC2/VEC3/VEC4, unsigned byte/short/int and
!     signed byte/short integer attributes (with `normalized`
!     handling), bufferView byteStride respected.
!   * Winding conversion kept from the original loader: glTF CCW
!     triangles are stored as (i1, i3, i2) to match the engine's
!     winding-cull convention; per-corner normals/UVs/tangents are
!     swapped along with the vertices.
!
! Robustness: any failure returns ok=.false. with a 0-triangle mesh;
! the loader never stops on bad input.
module gltf_loader
    use, intrinsic :: iso_fortran_env, only: int8, int32, int64, real32
    use math_3d
    use mesh_3d
    use json_reader_3d
    implicit none
    private
    public :: load_gltf, load_gltf_ex
    public :: GltfMaterial, GltfInfo, gltf_free_info

    integer, parameter :: CT_BYTE   = 5120
    integer, parameter :: CT_UBYTE  = 5121
    integer, parameter :: CT_SHORT  = 5122
    integer, parameter :: CT_USHORT = 5123
    integer, parameter :: CT_UINT   = 5125
    integer, parameter :: CT_FLOAT  = 5126

    type :: GltfMaterial
        character(len=64) :: name = ''
        real(dp) :: base_color(4) = [1.0_dp, 1.0_dp, 1.0_dp, 1.0_dp]
        real(dp) :: metallic = 0.0_dp
        real(dp) :: roughness = 1.0_dp
        integer :: base_color_tex = -1        ! texture index, -1 none
        character(len=256) :: base_color_tex_uri = ''
    end type GltfMaterial

    type :: GltfInfo
        type(GltfMaterial), allocatable :: materials(:)
        integer :: n_materials = 0
        ! Per-triangle-corner attributes in STORED (post winding-swap)
        ! corner order, matching mesh%triangles(t)%v(1..3).
        real(dp), allocatable :: tri_uv(:, :, :)       ! (t, corner, u/v)
        logical :: has_uv = .false.
        real(dp), allocatable :: tri_tangent(:, :, :)  ! (t, corner, xyzw)
        logical :: has_tangent = .false.
    end type GltfInfo

    ! One decoded buffer (bytes as unsigned values 0..255).
    type :: ByteBuf
        integer, allocatable :: b(:)
    end type ByteBuf

    type :: Accessor
        integer :: bv = -1, ctype = 0, count = 0, aoff = 0, ncomp = 0
        logical :: normalized = .false.
        logical :: valid = .false.
    end type Accessor

    type :: BufferView
        integer :: buffer = 0, boff = 0, blen = 0, stride = 0
        logical :: valid = .false.
    end type BufferView

    ! Loader working state (single-threaded loaders; module state is
    ! fine and keeps the recursive node walk readable).
    type(json_doc) :: g_doc
    type(ByteBuf), allocatable :: g_buffers(:)
    type(Accessor), allocatable :: g_acc(:)
    type(BufferView), allocatable :: g_bv(:)
    type(Triangle), allocatable :: g_tris(:)
    integer :: g_ntris = 0, g_tcap = 0
    real(dp), allocatable :: g_uv(:, :, :)
    real(dp), allocatable :: g_tan(:, :, :)
    logical :: g_has_uv = .false., g_has_tan = .false.
    type(GltfInfo) :: g_info

contains

    subroutine gltf_free_info(info)
        type(GltfInfo), intent(inout) :: info
        if (allocated(info%materials)) deallocate(info%materials)
        if (allocated(info%tri_uv)) deallocate(info%tri_uv)
        if (allocated(info%tri_tangent)) deallocate(info%tri_tangent)
        info%n_materials = 0
        info%has_uv = .false.
        info%has_tangent = .false.
    end subroutine gltf_free_info

    ! ----------------------------------------------------------------
    ! Byte-level helpers
    ! ----------------------------------------------------------------

    subroutine read_file_ubyte(path, buf, ok)
        character(len=*), intent(in) :: path
        integer, allocatable, intent(out) :: buf(:)
        logical, intent(out) :: ok
        integer(int8), allocatable :: raw(:)
        integer :: u, ios, fsize, i
        logical :: exists
        ok = .false.
        inquire(file=trim(path), exist=exists, size=fsize)
        if (.not. exists) return
        if (fsize <= 0) return
        allocate(raw(fsize))
        open(newunit=u, file=trim(path), status='old', action='read', &
             access='stream', form='unformatted', iostat=ios)
        if (ios /= 0) then
            deallocate(raw)
            return
        end if
        read(u, iostat=ios) raw
        close(u)
        if (ios /= 0) then
            deallocate(raw)
            return
        end if
        allocate(buf(fsize))
        do i = 1, fsize
            buf(i) = iand(int(raw(i), int32), 255)
        end do
        deallocate(raw)
        ok = .true.
    end subroutine read_file_ubyte

    subroutine base64_decode(s, buf, ok)
        character(len=*), intent(in) :: s
        integer, allocatable, intent(out) :: buf(:)
        logical, intent(out) :: ok
        character(len=*), parameter :: ALPHA = &
            'ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789+/'
        integer :: i, v, cap, nout, nbits
        integer(int32) :: acc
        integer, allocatable :: tmp(:)
        ok = .false.
        cap = (len_trim(s) * 3) / 4 + 8
        allocate(buf(cap))
        nout = 0
        nbits = 0
        acc = 0_int32
        do i = 1, len_trim(s)
            select case (s(i:i))
            case (' ', char(9), char(10), char(13))
                cycle
            case ('=')
                exit
            case default
                v = index(ALPHA, s(i:i))
                if (v == 0) then
                    deallocate(buf)
                    return
                end if
                v = v - 1
                acc = ior(ishft(acc, 6), int(v, int32))
                nbits = nbits + 6
                if (nbits >= 8) then
                    nbits = nbits - 8
                    nout = nout + 1
                    if (nout > cap) then
                        deallocate(buf)
                        return
                    end if
                    buf(nout) = int(iand(ishft(acc, -nbits), 255_int32))
                end if
            end select
        end do
        if (nout == 0) then
            deallocate(buf)
            return
        end if
        allocate(tmp(nout))
        tmp = buf(1:nout)
        call move_alloc(tmp, buf)
        ok = .true.
    end subroutine base64_decode

    function rd_u32(buf, p) result(v)  ! little-endian uint32 at byte p
        integer, intent(in) :: buf(:), p
        integer(int64) :: v
        v = int(buf(p), int64) + 256_int64 * int(buf(p + 1), int64) &
          + 65536_int64 * int(buf(p + 2), int64) &
          + 16777216_int64 * int(buf(p + 3), int64)
    end function rd_u32

    function rd_f32(buf, p) result(r)  ! little-endian float32 at byte p
        integer, intent(in) :: buf(:), p
        real(real32) :: r
        integer(int32) :: bits
        integer(int64) :: total
        total = rd_u32(buf, p)
        if (total >= 2147483648_int64) total = total - 4294967296_int64
        bits = int(total, int32)
        r = transfer(bits, r)
    end function rd_f32

    ! ----------------------------------------------------------------
    ! JSON convenience wrappers over json_reader_3d
    ! ----------------------------------------------------------------

    ! Child node of object `obj` for `key`, or 0.
    function jget(obj, key) result(child)
        integer, intent(in) :: obj
        character(len=*), intent(in) :: key
        integer :: child
        logical :: found
        call json_obj_get(g_doc, obj, key, child, found)
        if (.not. found) child = 0
    end function jget

    function jarr(obj, key) result(child)  ! member that should be an array
        integer, intent(in) :: obj
        character(len=*), intent(in) :: key
        integer :: child
        child = jget(obj, key)
        if (child /= 0) then
            if (json_kind(g_doc, child) /= 4) child = 0
        end if
    end function jarr

    ! k-th (1-based) element of array node, or 0.
    function jat(arr, k) result(child)
        integer, intent(in) :: arr, k
        integer :: child
        call json_arr_at(g_doc, arr, k, child)
    end function jat

    ! Number array member -> real array (up to n values), count returned.
    subroutine jnum_arr(obj, key, vals, n)
        integer, intent(in) :: obj
        character(len=*), intent(in) :: key
        real(dp), intent(out) :: vals(:)
        integer, intent(out) :: n
        integer :: arr, i, c
        n = 0
        arr = jarr(obj, key)
        if (arr == 0) return  ! absent: caller's defaults stay untouched
        do i = 1, min(json_arr_len(g_doc, arr), size(vals))
            c = jat(arr, i)
            if (c == 0) exit
            vals(i) = json_num(g_doc, c, 0.0_dp)
            n = i
        end do
    end subroutine jnum_arr

    ! ----------------------------------------------------------------
    ! Accessor decoding
    ! ----------------------------------------------------------------

    integer function comp_size(ctype) result(n)
        integer, intent(in) :: ctype
        select case (ctype)
        case (CT_BYTE, CT_UBYTE)
            n = 1
        case (CT_SHORT, CT_USHORT)
            n = 2
        case (CT_UINT, CT_FLOAT)
            n = 4
        case default
            n = 0
        end select
    end function comp_size

    integer function type_ncomp(tstr) result(n)
        character(len=*), intent(in) :: tstr
        select case (trim(tstr))
        case ('SCALAR')
            n = 1
        case ('VEC2')
            n = 2
        case ('VEC3')
            n = 3
        case ('VEC4')
            n = 4
        case default
            n = 0
        end select
    end function type_ncomp

    ! Read component `comp` (0-based) of element `elem` (0-based) of
    ! accessor `acc` as a real64, honouring stride, component type and
    ! the normalized flag.  Caller bounds-checks via accessor_setup.
    function acc_comp(acc, elem, comp) result(v)
        type(Accessor), intent(in) :: acc
        integer, intent(in) :: elem, comp
        real(dp) :: v
        type(BufferView) :: bv
        integer :: cs, stride, p, raw, bi
        bv = g_bv(acc%bv + 1)
        bi = bv%buffer + 1
        cs = comp_size(acc%ctype)
        stride = bv%stride
        if (stride == 0) stride = cs * acc%ncomp
        p = bv%boff + acc%aoff + elem * stride + comp * cs + 1  ! 1-based
        v = 0.0_dp
        select case (acc%ctype)
        case (CT_FLOAT)
            v = real(rd_f32(g_buffers(bi)%b, p), dp)
        case (CT_UBYTE)
            raw = g_buffers(bi)%b(p)
            if (acc%normalized) then
                v = real(raw, dp) / 255.0_dp
            else
                v = real(raw, dp)
            end if
        case (CT_BYTE)
            raw = g_buffers(bi)%b(p)
            if (raw >= 128) raw = raw - 256
            if (acc%normalized) then
                v = max(real(raw, dp) / 127.0_dp, -1.0_dp)
            else
                v = real(raw, dp)
            end if
        case (CT_USHORT)
            raw = g_buffers(bi)%b(p) + 256 * g_buffers(bi)%b(p + 1)
            if (acc%normalized) then
                v = real(raw, dp) / 65535.0_dp
            else
                v = real(raw, dp)
            end if
        case (CT_SHORT)
            raw = g_buffers(bi)%b(p) + 256 * g_buffers(bi)%b(p + 1)
            if (raw >= 32768) raw = raw - 65536
            if (acc%normalized) then
                v = max(real(raw, dp) / 32767.0_dp, -1.0_dp)
            else
                v = real(raw, dp)
            end if
        case (CT_UINT)
            v = real(rd_u32(g_buffers(bi)%b, p), dp)
        end select
    end function acc_comp

    ! Read an index element (integer accessors only).
    function acc_index(acc, elem) result(v)
        type(Accessor), intent(in) :: acc
        integer, intent(in) :: elem
        integer :: v
        v = nint(acc_comp(acc, elem, 0))
    end function acc_index

    ! Validate accessor idx and fill g_acc/g_bv tables (done up front).
    subroutine parse_tables(ok)
        logical, intent(out) :: ok
        integer :: arr, i, node, n, c
        character(len=:), allocatable :: tstr
        ok = .false.
        arr = jarr(g_doc%root, 'accessors')
        if (arr == 0) return
        n = json_arr_len(g_doc, arr)
        allocate(g_acc(n))
        do i = 1, n
            node = jat(arr, i)
            g_acc(i)%bv = json_int(g_doc, jget(node, 'bufferView'), -1)
            g_acc(i)%ctype = json_int(g_doc, jget(node, 'componentType'), 0)
            g_acc(i)%count = json_int(g_doc, jget(node, 'count'), 0)
            g_acc(i)%aoff = json_int(g_doc, jget(node, 'byteOffset'), 0)
            g_acc(i)%normalized = json_bool(g_doc, &
                jget(node, 'normalized'), .false.)
            tstr = json_str(g_doc, jget(node, 'type'))
            g_acc(i)%ncomp = type_ncomp(tstr)
            deallocate(tstr)
            g_acc(i)%valid = g_acc(i)%bv >= 0 .and. g_acc(i)%count > 0 &
                .and. comp_size(g_acc(i)%ctype) > 0 .and. g_acc(i)%ncomp > 0
        end do
        arr = jarr(g_doc%root, 'bufferViews')
        if (arr == 0) return
        n = json_arr_len(g_doc, arr)
        allocate(g_bv(n))
        do i = 1, n
            node = jat(arr, i)
            g_bv(i)%buffer = json_int(g_doc, jget(node, 'buffer'), 0)
            g_bv(i)%boff = json_int(g_doc, jget(node, 'byteOffset'), 0)
            g_bv(i)%blen = json_int(g_doc, jget(node, 'byteLength'), 0)
            g_bv(i)%stride = json_int(g_doc, jget(node, 'byteStride'), 0)
            g_bv(i)%valid = g_bv(i)%blen > 0 .and. g_bv(i)%buffer >= 0
        end do
        ! Cross-validate accessor byte ranges against buffer sizes.
        do i = 1, size(g_acc)
            if (.not. g_acc(i)%valid) cycle
            if (g_acc(i)%bv + 1 > size(g_bv)) then
                g_acc(i)%valid = .false.
                cycle
            end if
            if (.not. g_bv(g_acc(i)%bv + 1)%valid) then
                g_acc(i)%valid = .false.
                cycle
            end if
            associate (bv => g_bv(g_acc(i)%bv + 1), a => g_acc(i))
                if (bv%buffer + 1 > size(g_buffers)) then
                    a%valid = .false.
                else if (.not. allocated(g_buffers(bv%buffer + 1)%b)) then
                    a%valid = .false.
                else
                    block
                        integer :: cs, stride
                        integer(int64) :: last_byte, bufsz
                        cs = comp_size(a%ctype)
                        stride = bv%stride
                        if (stride == 0) stride = cs * a%ncomp
                        if (stride < cs * a%ncomp) then
                            a%valid = .false.
                        else
                            last_byte = int(bv%boff, int64) + &
                                int(a%aoff, int64) + &
                                int(a%count - 1, int64) * int(stride, int64) + &
                                int(cs * a%ncomp, int64)
                            bufsz = int(size(g_buffers(bv%buffer + 1)%b), int64)
                            if (last_byte > bufsz) a%valid = .false.
                        end if
                    end block
                end if
            end associate
            c = 0  ! (keeps -Wunused quiet about the loop helper above)
            if (c == -1) print *, 'never'
        end do
        ok = .true.
    end subroutine parse_tables

    ! ----------------------------------------------------------------
    ! Triangle accumulation
    ! ----------------------------------------------------------------

    subroutine push_tri(tri, uv, tan, has_uv_p, has_tan_p)
        type(Triangle), intent(in) :: tri
        real(dp), intent(in) :: uv(3, 2), tan(3, 4)
        logical, intent(in) :: has_uv_p, has_tan_p
        type(Triangle), allocatable :: ttmp(:)
        real(dp), allocatable :: utmp(:, :, :), atmp(:, :, :)
        integer :: new_cap
        if (g_ntris >= g_tcap) then
            new_cap = max(1024, 2 * g_tcap)
            allocate(ttmp(new_cap))
            allocate(utmp(new_cap, 3, 2))
            allocate(atmp(new_cap, 3, 4))
            if (g_ntris > 0) then
                ttmp(1:g_ntris) = g_tris(1:g_ntris)
                utmp(1:g_ntris, :, :) = g_uv(1:g_ntris, :, :)
                atmp(1:g_ntris, :, :) = g_tan(1:g_ntris, :, :)
            end if
            if (allocated(g_tris)) deallocate(g_tris)
            if (allocated(g_uv)) deallocate(g_uv)
            if (allocated(g_tan)) deallocate(g_tan)
            call move_alloc(ttmp, g_tris)
            call move_alloc(utmp, g_uv)
            call move_alloc(atmp, g_tan)
            g_tcap = new_cap
        end if
        g_ntris = g_ntris + 1
        g_tris(g_ntris) = tri
        g_uv(g_ntris, :, :) = uv
        g_tan(g_ntris, :, :) = tan
        if (has_uv_p) g_has_uv = .true.
        if (has_tan_p) g_has_tan = .true.
    end subroutine push_tri

    ! ----------------------------------------------------------------
    ! Materials
    ! ----------------------------------------------------------------

    subroutine parse_materials()
        integer :: arr, i, node, pbr, texnode, texidx, texarr, tnode
        real(dp) :: vals(4)
        integer :: n
        arr = jarr(g_doc%root, 'materials')
        if (arr == 0) then
            g_info%n_materials = 0
            allocate(g_info%materials(0))
            return
        end if
        n = json_arr_len(g_doc, arr)
        allocate(g_info%materials(n))
        g_info%n_materials = n
        do i = 1, n
            node = jat(arr, i)
            g_info%materials(i)%name = json_str(g_doc, jget(node, 'name'))
            pbr = jget(node, 'pbrMetallicRoughness')
            if (pbr /= 0) then
                call jnum_arr(pbr, 'baseColorFactor', vals, n)
                if (n >= 3) g_info%materials(i)%base_color(1:3) = vals(1:3)
                if (n >= 4) g_info%materials(i)%base_color(4) = vals(4)
                g_info%materials(i)%metallic = json_num(g_doc, &
                    jget(pbr, 'metallicFactor'), 0.0_dp)
                g_info%materials(i)%roughness = json_num(g_doc, &
                    jget(pbr, 'roughnessFactor'), 1.0_dp)
                texnode = jget(pbr, 'baseColorTexture')
                if (texnode /= 0) then
                    texidx = json_int(g_doc, jget(texnode, 'index'), -1)
                    g_info%materials(i)%base_color_tex = texidx
                    texarr = jarr(g_doc%root, 'textures')
                    if (texarr /= 0 .and. texidx >= 0) then
                        tnode = jat(texarr, texidx + 1)
                        if (tnode /= 0) then
                            block
                                integer :: imgidx, imgarr, inode
                                imgidx = json_int(g_doc, &
                                    jget(tnode, 'source'), -1)
                                imgarr = jarr(g_doc%root, 'images')
                                if (imgarr /= 0 .and. imgidx >= 0) then
                                    inode = jat(imgarr, imgidx + 1)
                                    if (inode /= 0) g_info%materials(i)% &
                                        base_color_tex_uri = json_str( &
                                            g_doc, jget(inode, 'uri'))
                                end if
                            end block
                        end if
                    end if
                end if
            end if
        end do
    end subroutine parse_materials

    ! ----------------------------------------------------------------
    ! Primitive + node walking
    ! ----------------------------------------------------------------

    subroutine process_primitive(prim, world)
        integer, intent(in) :: prim
        type(mat4), intent(in) :: world
        integer :: attrs, mode, mat_idx
        integer :: pos_i, nrm_i, uv_i, tan_i, idx_i
        type(Accessor) :: pa, na, ua, ta, ia
        logical :: has_n, has_u, has_t
        integer :: nv, ni, i, j, base
        integer, allocatable :: idxs(:)
        type(vec3), allocatable :: pos(:), nrm(:)
        real(dp), allocatable :: uvs(:, :), tans(:, :)
        type(Triangle) :: tri
        real(dp) :: tuv(3, 2), ttan(3, 4)
        integer :: order(3), src

        mode = json_int(g_doc, jget(prim, 'mode'), 4)
        if (mode /= 4) return  ! triangles only
        attrs = jget(prim, 'attributes')
        if (attrs == 0) return
        pos_i = json_int(g_doc, jget(attrs, 'POSITION'), -1)
        if (pos_i < 0 .or. pos_i + 1 > size(g_acc)) return
        pa = g_acc(pos_i + 1)
        if (.not. pa%valid .or. pa%ctype /= CT_FLOAT .or. pa%ncomp /= 3) return
        nrm_i = json_int(g_doc, jget(attrs, 'NORMAL'), -1)
        uv_i = json_int(g_doc, jget(attrs, 'TEXCOORD_0'), -1)
        tan_i = json_int(g_doc, jget(attrs, 'TANGENT'), -1)
        has_n = .false.; has_u = .false.; has_t = .false.
        if (nrm_i >= 0 .and. nrm_i + 1 <= size(g_acc)) then
            na = g_acc(nrm_i + 1)
            has_n = na%valid .and. na%ncomp == 3 .and. na%count == pa%count
        end if
        if (uv_i >= 0 .and. uv_i + 1 <= size(g_acc)) then
            ua = g_acc(uv_i + 1)
            has_u = ua%valid .and. ua%ncomp == 2 .and. ua%count == pa%count
        end if
        if (tan_i >= 0 .and. tan_i + 1 <= size(g_acc)) then
            ta = g_acc(tan_i + 1)
            has_t = ta%valid .and. ta%ncomp == 4 .and. ta%count == pa%count
        end if
        idx_i = json_int(g_doc, jget(prim, 'indices'), -1)
        nv = pa%count
        allocate(pos(nv), nrm(nv), uvs(nv, 2), tans(nv, 4))
        uvs = 0.0_dp
        tans = 0.0_dp
        do i = 1, nv
            pos(i) = mat4_transform_vec3(world, vec3_create( &
                acc_comp(pa, i - 1, 0), acc_comp(pa, i - 1, 1), &
                acc_comp(pa, i - 1, 2)), .true.)
            if (has_n) then
                nrm(i) = vec3_normalize(mat4_transform_vec3(world, &
                    vec3_create(acc_comp(na, i - 1, 0), &
                                acc_comp(na, i - 1, 1), &
                                acc_comp(na, i - 1, 2)), .false.))
            end if
            if (has_u) then
                uvs(i, 1) = acc_comp(ua, i - 1, 0)
                uvs(i, 2) = acc_comp(ua, i - 1, 1)
            end if
            if (has_t) then
                do j = 1, 4
                    tans(i, j) = acc_comp(ta, i - 1, j - 1)
                end do
            end if
        end do
        if (idx_i >= 0 .and. idx_i + 1 <= size(g_acc)) then
            ia = g_acc(idx_i + 1)
            if (.not. ia%valid) then
                deallocate(pos, nrm, uvs, tans)
                return
            end if
            ni = ia%count
            allocate(idxs(ni))
            do i = 1, ni
                idxs(i) = acc_index(ia, i - 1) + 1
                if (idxs(i) < 1 .or. idxs(i) > nv) then
                    deallocate(pos, nrm, uvs, tans, idxs)
                    return
                end if
            end do
        else
            ni = nv
            allocate(idxs(ni))
            do i = 1, ni
                idxs(i) = i
            end do
        end if
        mat_idx = json_int(g_doc, jget(prim, 'material'), -1)
        do base = 0, ni - 3, 3
            ! Winding conversion: stored order (i1, i3, i2).
            order = [idxs(base + 1), idxs(base + 3), idxs(base + 2)]
            do j = 1, 3
                src = order(j)
                tri%v(j) = pos(src)
                tuv(j, :) = uvs(src, :)
                ttan(j, :) = tans(src, :)
                if (has_n) tri%vn(j) = nrm(src)
            end do
            tri%normal = compute_triangle_normal(tri%v(1), tri%v(2), tri%v(3))
            if (has_n) then
                tri%smooth = .true.
            else
                tri%smooth = .false.
                tri%vn = [tri%normal, tri%normal, tri%normal]
            end if
            if (mat_idx >= 0 .and. mat_idx < g_info%n_materials) then
                tri%color = nint(255.0_dp * min(max( &
                    g_info%materials(mat_idx + 1)%base_color(1:3), &
                    0.0_dp), 1.0_dp))
                tri%material_id = mat_idx
            else
                tri%color = [255, 255, 255]
                tri%material_id = 0
                if (mat_idx >= 0) tri%material_id = mat_idx
            end if
            call push_tri(tri, tuv, ttan, has_u, has_t)
        end do
        deallocate(pos, nrm, uvs, tans, idxs)
    end subroutine process_primitive

    ! Local matrix of node `node`: explicit matrix, else T*R*S.
    function node_local(node) result(m)
        integer, intent(in) :: node
        type(mat4) :: m
        integer :: arr, i, j, c, n
        real(dp) :: vals(16), t(3), r(4), s(3)
        real(dp) :: x, y, z, w, xx, yy, zz, xy, xz, yz, wx, wy, wz
        m = mat4_identity()
        arr = jarr(node, 'matrix')
        if (arr /= 0) then
            ! glTF matrices are column-major: element (row, col) is
            ! stored at (col-1)*4 + row.
            do j = 1, 4
                do i = 1, 4
                    c = jat(arr, (j - 1) * 4 + i)
                    vals((j - 1) * 4 + i) = json_num(g_doc, c, 0.0_dp)
                    m%m(i, j) = vals((j - 1) * 4 + i)
                end do
            end do
            return
        end if
        t = [0.0_dp, 0.0_dp, 0.0_dp]
        r = [0.0_dp, 0.0_dp, 0.0_dp, 1.0_dp]
        s = [1.0_dp, 1.0_dp, 1.0_dp]
        call jnum_arr(node, 'translation', t, n)
        call jnum_arr(node, 'rotation', r, n)
        call jnum_arr(node, 'scale', s, n)
        x = r(1); y = r(2); z = r(3); w = r(4)
        xx = x * x; yy = y * y; zz = z * z
        xy = x * y; xz = x * z; yz = y * z
        wx = w * x; wy = w * y; wz = w * z
        m%m(1, 1) = (1.0_dp - 2.0_dp * (yy + zz)) * s(1)
        m%m(1, 2) = 2.0_dp * (xy - wz) * s(2)
        m%m(1, 3) = 2.0_dp * (xz + wy) * s(3)
        m%m(2, 1) = 2.0_dp * (xy + wz) * s(1)
        m%m(2, 2) = (1.0_dp - 2.0_dp * (xx + zz)) * s(2)
        m%m(2, 3) = 2.0_dp * (yz - wx) * s(3)
        m%m(3, 1) = 2.0_dp * (xz - wy) * s(1)
        m%m(3, 2) = 2.0_dp * (yz + wx) * s(2)
        m%m(3, 3) = (1.0_dp - 2.0_dp * (xx + yy)) * s(3)
        m%m(1, 4) = t(1)
        m%m(2, 4) = t(2)
        m%m(3, 4) = t(3)
    end function node_local

    recursive subroutine walk_node(node_idx, parent_world, depth)
        integer, intent(in) :: node_idx
        type(mat4), intent(in) :: parent_world
        integer, intent(in) :: depth
        integer :: nodes_arr, node, mesh_i, meshes_arr, meshnode
        integer :: prims, i, child_arr, cnode
        type(mat4) :: world
        if (depth > 64) return
        nodes_arr = jarr(g_doc%root, 'nodes')
        if (nodes_arr == 0) return
        node = jat(nodes_arr, node_idx + 1)
        if (node == 0) return
        world = mat4_mult(parent_world, node_local(node))
        mesh_i = json_int(g_doc, jget(node, 'mesh'), -1)
        if (mesh_i >= 0) then
            meshes_arr = jarr(g_doc%root, 'meshes')
            if (meshes_arr /= 0) then
                meshnode = jat(meshes_arr, mesh_i + 1)
                if (meshnode /= 0) then
                    prims = jarr(meshnode, 'primitives')
                    if (prims /= 0) then
                        do i = 1, json_arr_len(g_doc, prims)
                            call process_primitive(jat(prims, i), world)
                        end do
                    end if
                end if
            end if
        end if
        child_arr = jarr(node, 'children')
        if (child_arr /= 0) then
            do i = 1, json_arr_len(g_doc, child_arr)
                cnode = jat(child_arr, i)
                if (cnode /= 0) call walk_node( &
                    json_int(g_doc, cnode, -1), world, depth + 1)
            end do
        end if
    end subroutine walk_node

    ! ----------------------------------------------------------------
    ! Entry points
    ! ----------------------------------------------------------------

    subroutine load_gltf(path, mesh_out, ok)
        character(len=*), intent(in) :: path
        type(Mesh), intent(inout) :: mesh_out
        logical, intent(out) :: ok
        type(GltfInfo) :: info
        call load_gltf_ex(path, mesh_out, ok, info)
        call gltf_free_info(info)
    end subroutine load_gltf

    subroutine load_gltf_ex(path, mesh_out, ok, info)
        character(len=*), intent(in) :: path
        type(Mesh), intent(inout) :: mesh_out
        logical, intent(out) :: ok
        type(GltfInfo), intent(out) :: info

        integer, allocatable :: raw(:)
        integer, allocatable :: glb_bin(:)
        character(len=:), allocatable :: json_text, uri
        logical :: f, is_glb
        integer :: i, slash, comma, nbuf_nodes
        integer :: buffers_arr, bnode
        character(len=256) :: errmsg

        ok = .false.
        info = GltfInfo()
        g_info = GltfInfo()
        g_ntris = 0; g_tcap = 0
        g_has_uv = .false.; g_has_tan = .false.
        if (allocated(g_tris)) deallocate(g_tris)
        if (allocated(g_uv)) deallocate(g_uv)
        if (allocated(g_tan)) deallocate(g_tan)
        if (allocated(g_acc)) deallocate(g_acc)
        if (allocated(g_bv)) deallocate(g_bv)
        if (allocated(g_buffers)) deallocate(g_buffers)
        if (allocated(mesh_out%triangles)) deallocate(mesh_out%triangles)
        mesh_out%num_triangles = 0
        allocate(mesh_out%triangles(0))

        call read_file_ubyte(trim(path), raw, f)
        if (.not. f) return

        ! ---- container: .glb or plain .gltf JSON ----
        is_glb = .false.
        if (size(raw) >= 12) then
            if (raw(1) == iachar('g') .and. raw(2) == iachar('l') .and. &
                raw(3) == iachar('T') .and. raw(4) == iachar('F')) &
                is_glb = .true.
        end if
        if (is_glb) then
            block
                integer(int64) :: clen, ctype
                integer :: p
                if (rd_u32(raw, 5) /= 2_int64) then
                    deallocate(raw)
                    return
                end if
                p = 13  ! first chunk header (1-based byte position)
                if (p + 7 > size(raw)) then
                    deallocate(raw)
                    return
                end if
                clen = rd_u32(raw, p)
                ctype = rd_u32(raw, p + 4)
                if (ctype /= int(z'4E4F534A', int64)) then  ! 'JSON'
                    deallocate(raw)
                    return
                end if
                if (p + 7 + int(clen) > size(raw)) then
                    deallocate(raw)
                    return
                end if
                allocate(character(len=int(clen)) :: json_text)
                do i = 1, int(clen)
                    json_text(i:i) = achar(raw(p + 7 + i))
                end do
                p = p + 8 + int(clen)
                if (p + 7 <= size(raw)) then
                    clen = rd_u32(raw, p)
                    ctype = rd_u32(raw, p + 4)
                    if (ctype == int(z'004E4942', int64)) then  ! 'BIN\0'
                        if (p + 7 + int(clen) > size(raw)) then
                            deallocate(raw)
                            return
                        end if
                        allocate(glb_bin(int(clen)))
                        glb_bin = raw(p + 8:p + 7 + int(clen))
                    end if
                end if
            end block
        else
            allocate(character(len=size(raw)) :: json_text)
            do i = 1, size(raw)
                json_text(i:i) = achar(raw(i))
            end do
        end if
        deallocate(raw)

        call json_parse(json_text, g_doc, f, errmsg)
        deallocate(json_text)
        if (.not. f) return
        if (json_kind(g_doc, g_doc%root) /= 5) then
            call json_free(g_doc)
            return
        end if

        ! ---- buffers ----
        buffers_arr = jarr(g_doc%root, 'buffers')
        if (buffers_arr == 0) then
            call json_free(g_doc)
            return
        end if
        nbuf_nodes = json_arr_len(g_doc, buffers_arr)
        if (nbuf_nodes <= 0) then
            call json_free(g_doc)
            return
        end if
        allocate(g_buffers(nbuf_nodes))
        do i = 1, nbuf_nodes
            bnode = jat(buffers_arr, i)
            if (bnode == 0) cycle
            uri = json_str(g_doc, jget(bnode, 'uri'))
            if (len_trim(uri) == 0) then
                ! No URI: the GLB BIN chunk (buffer 0 only, per spec).
                if (i == 1 .and. allocated(glb_bin)) then
                    allocate(g_buffers(i)%b(size(glb_bin)))
                    g_buffers(i)%b = glb_bin
                end if
            else if (len(uri) >= 5 .and. uri(1:5) == 'data:') then
                comma = index(uri, ',')
                if (comma > 0 .and. index(uri(1:comma), 'base64') > 0) then
                    call base64_decode(uri(comma + 1:), g_buffers(i)%b, f)
                    if (.not. f .and. allocated(g_buffers(i)%b)) &
                        deallocate(g_buffers(i)%b)
                end if
            else
                slash = index(trim(path), '/', back=.true.)
                if (slash > 0) then
                    call read_file_ubyte(trim(path(1:slash)) // trim(uri), &
                                         g_buffers(i)%b, f)
                else
                    call read_file_ubyte(trim(uri), g_buffers(i)%b, f)
                end if
                if (.not. f .and. allocated(g_buffers(i)%b)) &
                    deallocate(g_buffers(i)%b)
            end if
            if (allocated(uri)) deallocate(uri)
        end do
        if (allocated(glb_bin)) deallocate(glb_bin)

        call parse_tables(f)
        if (.not. f) then
            call cleanup()
            return
        end if
        call parse_materials()

        ! ---- scene walk ----
        block
            integer :: scenes_arr, snode, roots, scene_idx, rnode
            type(mat4) :: ident
            ident = mat4_identity()
            scene_idx = json_int(g_doc, jget(g_doc%root, 'scene'), 0)
            scenes_arr = jarr(g_doc%root, 'scenes')
            if (scenes_arr /= 0 .and. scene_idx >= 0) then
                snode = jat(scenes_arr, scene_idx + 1)
                if (snode /= 0) then
                    roots = jarr(snode, 'nodes')
                    if (roots /= 0) then
                        do i = 1, json_arr_len(g_doc, roots)
                            rnode = jat(roots, i)
                            if (rnode /= 0) call walk_node( &
                                json_int(g_doc, rnode, -1), ident, 0)
                        end do
                    end if
                end if
            end if
            if (g_ntris == 0) then
                ! Fallback (matches the old loader's reach): no scene
                ! graph -- load every mesh with identity transforms.
                block
                    integer :: meshes_arr, mnode, prims, j
                    meshes_arr = jarr(g_doc%root, 'meshes')
                    if (meshes_arr /= 0) then
                        do i = 1, json_arr_len(g_doc, meshes_arr)
                            mnode = jat(meshes_arr, i)
                            if (mnode == 0) cycle
                            prims = jarr(mnode, 'primitives')
                            if (prims == 0) cycle
                            do j = 1, json_arr_len(g_doc, prims)
                                call process_primitive(jat(prims, j), ident)
                            end do
                        end do
                    end if
                end block
            end if
        end block

        if (g_ntris <= 0) then
            call cleanup()
            return
        end if
        deallocate(mesh_out%triangles)
        allocate(mesh_out%triangles(g_ntris))
        mesh_out%triangles(1:g_ntris) = g_tris(1:g_ntris)
        mesh_out%num_triangles = g_ntris
        info%materials = g_info%materials
        info%n_materials = g_info%n_materials
        allocate(info%tri_uv(g_ntris, 3, 2))
        info%tri_uv = g_uv(1:g_ntris, :, :)
        info%has_uv = g_has_uv
        allocate(info%tri_tangent(g_ntris, 3, 4))
        info%tri_tangent = g_tan(1:g_ntris, :, :)
        info%has_tangent = g_has_tan
        ! Ownership of g_info%materials moved to info.
        if (allocated(g_info%materials)) deallocate(g_info%materials)
        g_info%n_materials = 0
        ok = .true.
        call cleanup()

    contains

        subroutine cleanup()
            integer :: bi
            call json_free(g_doc)
            if (allocated(g_buffers)) then
                do bi = 1, size(g_buffers)
                    if (allocated(g_buffers(bi)%b)) &
                        deallocate(g_buffers(bi)%b)
                end do
                deallocate(g_buffers)
            end if
            if (allocated(g_acc)) deallocate(g_acc)
            if (allocated(g_bv)) deallocate(g_bv)
            if (allocated(g_tris)) deallocate(g_tris)
            if (allocated(g_uv)) deallocate(g_uv)
            if (allocated(g_tan)) deallocate(g_tan)
            if (allocated(g_info%materials)) deallocate(g_info%materials)
            g_info%n_materials = 0
            g_ntris = 0
            g_tcap = 0
        end subroutine cleanup

    end subroutine load_gltf_ex

end module gltf_loader
