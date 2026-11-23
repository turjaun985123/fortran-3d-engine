! gltf_loader.f90 -- native Fortran glTF loader (Forge3D Wave B, B64;
! MASTER-PLAN row 19, Fortran ingest half).
!
! Public API (frozen):
!   subroutine load_gltf(path, mesh, ok)   ! positional; mesh is a Mesh
!     path : character(len=*)  -- path to a .gltf (JSON text) file
!     mesh : type(Mesh)        -- mesh_3d Mesh, filled on success
!     ok   : logical           -- .true. on success
!
! SUPPORTED SUBSET (deliberately small -- this is NOT a full glTF 2.0
! implementation):
!   * .gltf JSON text only.  Binary .glb is NOT supported.
!   * First mesh, first primitive only.
!   * buffers[0] only, given either as a "data:...;base64,...." URI
!     (decoded by the built-in base64 decoder) or as an external file
!     (e.g. ".bin") resolved relative to the .gltf file's directory.
!   * POSITION attribute: componentType 5126 (float32), type "VEC3",
!     little-endian, tightly packed or with a bufferView byteStride.
!   * Indices: optional; componentType 5121 (uint8), 5123 (uint16) or
!     5125 (uint32), type "SCALAR".  Without an indices accessor the
!     vertices are consumed sequentially in groups of three.
!   * Triangle topology only (primitive mode 4 or absent); every three
!     indices / vertices form one triangle.
!   * Winding conversion: glTF uses a counter-clockwise (CCW) front-face
!     winding, but the Forge3D rasteriser's screen-space winding cull
!     keeps only triangles matching the engine's far-side convention
!     (the convention all engine primitives use), so glTF CCW triangles
!     would render zero pixels.  Each output triangle is therefore
!     stored with its second and third vertices swapped -- indices
!     (i1, i2, i3) are stored as (i1, i3, i2) -- matching the
!     compiler-side converter (compiler/src/f3dc_ext_gltf.f90) so
!     both ingest paths
!     produce identical, engine-visible meshes.  The computed flat
!     normal consequently flips sign relative to the raw glTF winding,
!     which is expected and consistent with the engine convention.
!   * No node transforms (identity), no skins, morphs, animations,
!     materials, textures or extensions.
!   * COLOR_0 and all other attributes (NORMAL, TEXCOORD_0, ...) are
!     ignored: every triangle gets colour (255,255,255) and a flat
!     normal computed with mesh_3d's compute_triangle_normal.
!
! How it finds the data (pragmatic scanning, no JSON library): the
! first "POSITION":<n> and "indices":<n> integers in the document are
! taken as the accessor indices; accessor n is the n-th object of the
! "accessors" array and bufferView n the n-th object of the
! "bufferViews" array (objects are matched by balanced braces).
!
! Robustness: any failure (missing file, malformed JSON, unsupported
! component type, out-of-range offset, ...) returns ok = .false. with
! a mesh of 0 triangles.  This loader never stops / crashes on bad
! input.
module gltf_loader
    use, intrinsic :: iso_fortran_env, only: int8, int32, int64, real32
    use math_3d
    use mesh_3d
    implicit none
    private
    public :: load_gltf

    ! glTF componentType codes.
    integer, parameter :: CT_BYTE   = 5120
    integer, parameter :: CT_UBYTE  = 5121
    integer, parameter :: CT_SHORT  = 5122
    integer, parameter :: CT_USHORT = 5123
    integer, parameter :: CT_UINT   = 5125
    integer, parameter :: CT_FLOAT  = 5126

contains

    ! ------------------------------------------------------------------
    ! Low-level helpers
    ! ------------------------------------------------------------------

    ! Read a whole file as unsigned byte values (0..255) in buf.
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

    ! Parse the integer that follows position `from` in s (skipping
    ! spaces/tabs/newlines and one optional ':'), starting the scan at
    ! or after `from`.  Returns found=.false. if there is no integer.
    subroutine parse_int_after(s, from, val, found)
        character(len=*), intent(in) :: s
        integer, intent(in) :: from
        integer, intent(out) :: val
        logical, intent(out) :: found
        integer :: i, n, sign, digits
        integer(int64) :: acc

        val = 0
        found = .false.
        n = len(s)
        i = max(1, from)
        ! Skip separators (whitespace and the ':' after a key).
        do while (i <= n)
            if (s(i:i) == ' ' .or. s(i:i) == char(9) .or. &
                s(i:i) == char(10) .or. s(i:i) == char(13) .or. &
                s(i:i) == ':') then
                i = i + 1
            else
                exit
            end if
        end do
        sign = 1
        if (i <= n) then
            if (s(i:i) == '-') then
                sign = -1
                i = i + 1
            else if (s(i:i) == '+') then
                i = i + 1
            end if
        end if
        acc = 0_int64
        digits = 0
        do while (i <= n)
            if (s(i:i) >= '0' .and. s(i:i) <= '9') then
                acc = acc * 10_int64 + int(iachar(s(i:i)) - iachar('0'), int64)
                digits = digits + 1
                i = i + 1
            else
                exit
            end if
        end do
        if (digits == 0) return
        if (acc > int(huge(val), int64)) return
        val = int(sign * acc)
        found = .true.
    end subroutine parse_int_after

    ! Value of the first "<key>":<int> in s (whole string or one JSON
    ! object).  The key is matched with its surrounding quotes, so
    ! "buffer" does not match "bufferView".
    subroutine key_int(s, key, val, found)
        character(len=*), intent(in) :: s, key
        integer, intent(out) :: val
        logical, intent(out) :: found
        character(len=:), allocatable :: pat
        integer :: p

        val = 0
        found = .false.
        pat = '"' // trim(key) // '"'
        p = index(s, pat)
        if (p == 0) return
        call parse_int_after(s, p + len(pat), val, found)
    end subroutine key_int

    ! Value of the first "<key>":"<string>" in s.  No escape handling
    ! beyond skipping a backslash-escaped quote (URIs in the supported
    ! subset need nothing more).
    subroutine key_string(s, key, val, found)
        character(len=*), intent(in) :: s, key
        character(len=:), allocatable, intent(out) :: val
        logical, intent(out) :: found
        character(len=:), allocatable :: pat
        integer :: p, i, n, start

        found = .false.
        pat = '"' // trim(key) // '"'
        p = index(s, pat)
        if (p == 0) return
        n = len(s)
        i = p + len(pat)
        ! Skip to the ':' then to the opening quote of the value.
        do while (i <= n .and. s(i:i) /= ':')
            i = i + 1
        end do
        i = i + 1
        do while (i <= n .and. s(i:i) /= '"')
            i = i + 1
        end do
        if (i > n) return
        start = i + 1
        i = start
        do while (i <= n)
            if (s(i:i) == '\' .and. i < n) then
                i = i + 2
                cycle
            end if
            if (s(i:i) == '"') exit
            i = i + 1
        end do
        if (i > n) return
        allocate(character(len=max(0, i - start)) :: val)
        if (i > start) val = s(start:i - 1)
        found = .true.
    end subroutine key_string

    ! Position (1-based) of the '}' matching the '{' at s(start),
    ! honouring string literals.  0 if unbalanced.
    function match_brace(s, start) result(fin)
        character(len=*), intent(in) :: s
        integer, intent(in) :: start
        integer :: fin, i, n, depth
        logical :: in_str, esc

        fin = 0
        n = len(s)
        depth = 0
        in_str = .false.
        esc = .false.
        do i = start, n
            if (in_str) then
                if (esc) then
                    esc = .false.
                else if (s(i:i) == '\') then
                    esc = .true.
                else if (s(i:i) == '"') then
                    in_str = .false.
                end if
                cycle
            end if
            select case (s(i:i))
            case ('"')
                in_str = .true.
            case ('{')
                depth = depth + 1
            case ('}')
                depth = depth - 1
                if (depth == 0) then
                    fin = i
                    return
                end if
                if (depth < 0) return
            end select
        end do
    end function match_brace

    ! Extract the n-th (0-based) object of the JSON array stored under
    ! "<key>": [ {...}, {...}, ... ] in s.
    subroutine array_object(s, key, n, obj, found)
        character(len=*), intent(in) :: s, key
        integer, intent(in) :: n
        character(len=:), allocatable, intent(out) :: obj
        logical, intent(out) :: found
        character(len=:), allocatable :: pat
        integer :: i, slen, k, fin

        found = .false.
        pat = '"' // trim(key) // '"'
        i = index(s, pat)
        if (i == 0) return
        i = i + len(pat)
        slen = len(s)
        do while (i <= slen .and. s(i:i) /= '[')
            i = i + 1
        end do
        if (i > slen) return
        i = i + 1
        do k = 0, n
            ! Skip whitespace and commas between objects.
            do while (i <= slen)
                if (s(i:i) == ' ' .or. s(i:i) == ',' .or. &
                    s(i:i) == char(9) .or. s(i:i) == char(10) .or. &
                    s(i:i) == char(13)) then
                    i = i + 1
                else
                    exit
                end if
            end do
            if (i > slen .or. s(i:i) /= '{') return
            fin = match_brace(s, i)
            if (fin == 0) return
            if (k == n) then
                allocate(character(len=fin - i + 1) :: obj)
                obj = s(i:fin)
                found = .true.
                return
            end if
            i = fin + 1
        end do
    end subroutine array_object

    ! Decode a base64 string (standard alphabet, '=' padding) into
    ! unsigned byte values.  Whitespace is ignored; any other foreign
    ! character is a failure.
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
                exit  ! padding: nothing more can follow usefully
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
        ! Shrink to the decoded size.
        allocate(tmp(nout))
        tmp = buf(1:nout)
        call move_alloc(tmp, buf)
        ok = .true.
    end subroutine base64_decode

    ! Little-endian float32 at 1-based byte position p of buf.
    function read_f32_le(buf, p) result(r)
        integer, intent(in) :: buf(:)
        integer, intent(in) :: p
        real(real32) :: r
        integer(int32) :: bits
        integer(int64) :: total

        total = int(buf(p), int64) + 256_int64 * int(buf(p + 1), int64) &
              + 65536_int64 * int(buf(p + 2), int64) &
              + 16777216_int64 * int(buf(p + 3), int64)
        if (total >= 2147483648_int64) total = total - 4294967296_int64
        bits = int(total, int32)
        r = transfer(bits, r)
    end function read_f32_le

    ! Unsigned index of `size` bytes (1, 2 or 4), little-endian, at
    ! 1-based byte position p of buf.
    function read_uint_le(buf, p, size) result(v)
        integer, intent(in) :: buf(:), p, size
        integer :: v
        integer(int64) :: total

        select case (size)
        case (1)
            total = int(buf(p), int64)
        case (2)
            total = int(buf(p), int64) + 256_int64 * int(buf(p + 1), int64)
        case default  ! 4
            total = int(buf(p), int64) + 256_int64 * int(buf(p + 1), int64) &
                  + 65536_int64 * int(buf(p + 2), int64) &
                  + 16777216_int64 * int(buf(p + 3), int64)
        end select
        v = int(total)
    end function read_uint_le

    ! ------------------------------------------------------------------
    ! Accessor / bufferView extraction
    ! ------------------------------------------------------------------

    ! Fill the fields of accessor `idx` from the JSON text.
    subroutine get_accessor(json, idx, bv, ctype, count, aoff, type_str, found)
        character(len=*), intent(in) :: json
        integer, intent(in) :: idx
        integer, intent(out) :: bv, ctype, count, aoff
        character(len=:), allocatable, intent(out) :: type_str
        logical, intent(out) :: found
        character(len=:), allocatable :: obj
        logical :: f

        bv = -1; ctype = -1; count = -1; aoff = 0
        found = .false.
        call array_object(json, 'accessors', idx, obj, f)
        if (.not. f) return
        call key_int(obj, 'bufferView', bv, f)
        if (.not. f) return
        call key_int(obj, 'componentType', ctype, f)
        if (.not. f) return
        call key_int(obj, 'count', count, f)
        if (.not. f) return
        call key_int(obj, 'byteOffset', aoff, f)
        if (.not. f) aoff = 0  ! optional, defaults to 0
        call key_string(obj, 'type', type_str, f)
        if (.not. f) return
        found = .true.
    end subroutine get_accessor

    ! Fill the fields of bufferView `idx` from the JSON text.
    subroutine get_bufferview(json, idx, boff, blen, bidx, stride, found)
        character(len=*), intent(in) :: json
        integer, intent(in) :: idx
        integer, intent(out) :: boff, blen, bidx, stride
        logical, intent(out) :: found
        character(len=:), allocatable :: obj
        logical :: f

        boff = 0; blen = -1; bidx = 0; stride = 0
        found = .false.
        call array_object(json, 'bufferViews', idx, obj, f)
        if (.not. f) return
        call key_int(obj, 'byteLength', blen, f)
        if (.not. f) return
        call key_int(obj, 'byteOffset', boff, f)
        if (.not. f) boff = 0  ! optional, defaults to 0
        call key_int(obj, 'buffer', bidx, f)
        if (.not. f) bidx = 0  ! optional, defaults to 0
        call key_int(obj, 'byteStride', stride, f)
        if (.not. f) stride = 0  ! optional; 0 = tightly packed
        found = .true.
    end subroutine get_bufferview

    ! ------------------------------------------------------------------
    ! Main entry point
    ! ------------------------------------------------------------------

    subroutine load_gltf(path, mesh_out, ok)
        character(len=*), intent(in) :: path
        type(Mesh), intent(inout) :: mesh_out
        logical, intent(out) :: ok

        integer, allocatable :: raw(:)
        integer, allocatable :: buf(:)
        character(len=:), allocatable :: json, uri, type_str
        character(len=:), allocatable :: obj0
        logical :: f, is_data_uri
        integer :: i, k, slash, comma
        integer :: pos_acc, idx_acc
        integer :: pos_bv, pos_ct, pos_count, pos_aoff
        integer :: pos_boff, pos_blen, pos_bidx, pos_stride
        integer :: idx_bv, idx_ct, idx_count, idx_aoff
        integer :: idx_boff, idx_blen, idx_bidx, idx_stride
        integer :: pos_off, idx_off, pos_esize, idx_esize
        integer :: nbuf, ntris
        type(vec3), allocatable :: verts(:)
        integer, allocatable :: indices(:)
        type(Triangle) :: tri

        ok = .false.
        if (allocated(mesh_out%triangles)) deallocate(mesh_out%triangles)
        mesh_out%num_triangles = 0
        allocate(mesh_out%triangles(0))

        ! (a) Read the whole .gltf file as characters.
        call read_file_ubyte(trim(path), raw, f)
        if (.not. f) return
        allocate(character(len=size(raw)) :: json)
        do i = 1, size(raw)
            json(i:i) = achar(raw(i))
        end do
        deallocate(raw)

        ! (b) First "POSITION" / "indices" accessor indices.
        call key_int(json, 'POSITION', pos_acc, f)
        if (.not. f .or. pos_acc < 0) return
        call key_int(json, 'indices', idx_acc, f)
        if (.not. f) idx_acc = -1  ! non-indexed geometry is allowed
        if (idx_acc < -1) return

        ! Accessors + bufferViews for POSITION (and indices if any).
        call get_accessor(json, pos_acc, pos_bv, pos_ct, pos_count, &
                          pos_aoff, type_str, f)
        if (.not. f) return
        if (pos_ct /= CT_FLOAT .or. trim(type_str) /= 'VEC3') return
        if (pos_count <= 0 .or. pos_bv < 0) return
        call get_bufferview(json, pos_bv, pos_boff, pos_blen, pos_bidx, &
                            pos_stride, f)
        if (.not. f .or. pos_bidx /= 0 .or. pos_blen <= 0) return
        pos_esize = 12
        if (pos_stride == 0) pos_stride = pos_esize
        if (pos_stride < pos_esize) return
        pos_off = pos_boff + pos_aoff  ! 0-based byte offset into buffer

        idx_off = 0; idx_esize = 0; idx_count = 0
        if (idx_acc >= 0) then
            call get_accessor(json, idx_acc, idx_bv, idx_ct, idx_count, &
                              idx_aoff, type_str, f)
            if (.not. f) return
            if (trim(type_str) /= 'SCALAR' .or. idx_count <= 0) return
            if (idx_bv < 0) return
            select case (idx_ct)
            case (CT_UBYTE)
                idx_esize = 1
            case (CT_USHORT)
                idx_esize = 2
            case (CT_UINT)
                idx_esize = 4
            case default
                return
            end select
            call get_bufferview(json, idx_bv, idx_boff, idx_blen, &
                                idx_bidx, idx_stride, f)
            if (.not. f .or. idx_bidx /= 0 .or. idx_blen <= 0) return
            if (idx_stride == 0) idx_stride = idx_esize
            if (idx_stride < idx_esize) return
            idx_off = idx_boff + idx_aoff
        end if

        ! (c) buffers[0]: data URI (base64) or external file.
        call array_object(json, 'buffers', 0, obj0, f)
        if (.not. f) return
        call key_string(obj0, 'uri', uri, f)
        if (.not. f) return  ! embedded GLB-style buffers unsupported
        is_data_uri = (len(uri) >= 5 .and. uri(1:5) == 'data:')
        if (is_data_uri) then
            comma = index(uri, ',')
            if (comma == 0) return
            if (index(uri(1:comma), 'base64') == 0) return
            if (comma >= len(uri)) return
            call base64_decode(uri(comma + 1:), buf, f)
            if (.not. f) return
        else
            ! Resolve relative to the .gltf file's directory.
            slash = index(trim(path), '/', back=.true.)
            if (slash > 0) then
                call read_file_ubyte(trim(path(1:slash)) // trim(uri), buf, f)
            else
                call read_file_ubyte(trim(uri), buf, f)
            end if
            if (.not. f) return
        end if
        nbuf = size(buf)

        ! Bounds-check every byte range we are about to read.
        if (pos_off < 0) return
        if (int(pos_off, int64) + int(pos_count - 1, int64) * &
            int(pos_stride, int64) + int(pos_esize, int64) > &
            int(nbuf, int64)) return
        if (idx_acc >= 0) then
            if (idx_off < 0) return
            if (int(idx_off, int64) + int(idx_count - 1, int64) * &
                int(idx_stride, int64) + int(idx_esize, int64) > &
                int(nbuf, int64)) return
        end if

        ! (d) Decode positions (little-endian float32 -> dp vec3).
        allocate(verts(pos_count))
        do i = 1, pos_count
            k = pos_off + (i - 1) * pos_stride + 1  ! 1-based byte pos
            verts(i) = vec3_create( &
                real(read_f32_le(buf, k), dp), &
                real(read_f32_le(buf, k + 4), dp), &
                real(read_f32_le(buf, k + 8), dp))
        end do

        ! Decode indices, or synthesise the sequential order.
        if (idx_acc >= 0) then
            if (mod(idx_count, 3) /= 0) then
                deallocate(verts)
                return
            end if
            allocate(indices(idx_count))
            do i = 1, idx_count
                k = idx_off + (i - 1) * idx_stride + 1
                indices(i) = read_uint_le(buf, k, idx_esize) + 1  ! to 1-based
                if (indices(i) < 1 .or. indices(i) > pos_count) then
                    deallocate(verts, indices)
                    return
                end if
            end do
            ntris = idx_count / 3
        else
            if (mod(pos_count, 3) /= 0) then
                deallocate(verts)
                return
            end if
            allocate(indices(pos_count))
            do i = 1, pos_count
                indices(i) = i
            end do
            ntris = pos_count / 3
        end if
        deallocate(buf)
        if (ntris <= 0) then
            deallocate(verts, indices)
            return
        end if

        ! Build the mesh: white triangles with computed flat normals.
        deallocate(mesh_out%triangles)
        allocate(mesh_out%triangles(ntris))
        do i = 1, ntris
            ! Winding conversion (see header): store (i1, i3, i2),
            ! swapping v2 <-> v3 so glTF CCW triangles match the
            ! engine's winding-cull convention and render.
            tri%v(1) = verts(indices(3 * i - 2))
            tri%v(2) = verts(indices(3 * i))
            tri%v(3) = verts(indices(3 * i - 1))
            tri%normal = compute_triangle_normal(tri%v(1), tri%v(2), tri%v(3))
            tri%color = [255, 255, 255]
            tri%material_id = 0
            mesh_out%triangles(i) = tri
        end do
        mesh_out%num_triangles = ntris
        deallocate(verts, indices)
        ok = .true.
    end subroutine load_gltf

end module gltf_loader
