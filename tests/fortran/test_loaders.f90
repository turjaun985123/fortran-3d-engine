! test_loaders.f90 -- tests for the rewritten OBJ and glTF readers
! (v3.0 Phase 1, finding G2):
!   (a) OBJ fixture with vt/vn/groups/two materials
!   (b) minimal .glb built in-program (JSON + BIN chunks, indexed
!       quad with POSITION/NORMAL/TEXCOORD_0)
!   (c) the same scene as .gltf + external .bin
!   (d) glTF node hierarchy transform (translation + rotation)
!   (e) 100k-triangle OBJ load timing smoke check
program test_loaders
    use, intrinsic :: iso_fortran_env, only: real32, real64, int16, int32, int8
    use math_3d
    use mesh_3d
    use obj_loader
    use gltf_loader
    use test_assert
    implicit none

    type(Mesh) :: m
    type(ObjInfo) :: oi
    type(GltfInfo) :: gi
    logical :: ok, exists
    integer :: u, i
    character(len=512) :: obj_path
    character(len=256) :: home, scratch
    real(real64) :: t0, t1, elapsed
    integer :: status

    ! ==================================================================
    ! (a) OBJ fixture
    ! ==================================================================
    obj_path = ''
    do i = 1, 3
        select case (i)
        case (1)
            obj_path = 'tests/fortran/fixtures/quad.obj'
        case (2)
            obj_path = '../tests/fortran/fixtures/quad.obj'
        case (3)
            obj_path = '../../tests/fortran/fixtures/quad.obj'
        end select
        inquire(file=trim(obj_path), exist=exists)
        if (exists) exit
        obj_path = ''
    end do
    if (len_trim(obj_path) == 0) then
        ! Fallback: reconstruct the identical fixture under /tmp.
        call execute_command_line('mkdir -p /tmp/f3d_quad_fixture')
        open(newunit=u, file='/tmp/f3d_quad_fixture/quad.mtl', &
             status='replace', action='write')
        write(u, '(A)') 'newmtl red'
        write(u, '(A)') 'Ka 0.1 0.0 0.0'
        write(u, '(A)') 'Kd 1.0 0.0 0.0'
        write(u, '(A)') 'Ks 0.5 0.5 0.5'
        write(u, '(A)') 'map_Kd red.png'
        write(u, '(A)') 'newmtl blue'
        write(u, '(A)') 'Ka 0.0 0.0 0.1'
        write(u, '(A)') 'Kd 0.0 0.0 1.0'
        write(u, '(A)') 'Ks 0.25 0.25 0.25'
        write(u, '(A)') 'map_Kd blue.png'
        close(u)
        open(newunit=u, file='/tmp/f3d_quad_fixture/quad.obj', &
             status='replace', action='write')
        write(u, '(A)') 'mtllib quad.mtl'
        write(u, '(A)') 'v 0.0 0.0 0.0'
        write(u, '(A)') 'v 1.0 0.0 0.0'
        write(u, '(A)') 'v 1.0 1.0 0.0'
        write(u, '(A)') 'v 0.0 1.0 0.0'
        write(u, '(A)') 'v 0.0 0.0 1.0'
        write(u, '(A)') 'v 1.0 0.0 1.0'
        write(u, '(A)') 'v 1.0 1.0 1.0'
        write(u, '(A)') 'v 0.0 1.0 1.0'
        write(u, '(A)') 'vt 0.0 0.0'
        write(u, '(A)') 'vt 1.0 0.0'
        write(u, '(A)') 'vt 1.0 1.0'
        write(u, '(A)') 'vt 0.0 1.0'
        write(u, '(A)') 'vn 0.0 0.0 1.0'
        write(u, '(A)') 'vn 0.0 0.0 -1.0'
        write(u, '(A)') 'g first'
        write(u, '(A)') 'usemtl red'
        write(u, '(A)') 'f 1/1/1 2/2/1 3/3/1'
        write(u, '(A)') 'g second'
        write(u, '(A)') 'usemtl blue'
        write(u, '(A)') 'f 1/1/1 3/3/1 4/4/1'
        write(u, '(A)') 'g third'
        write(u, '(A)') 'f -4//2 -3//2 -2//2 -1//2'
        close(u)
        obj_path = '/tmp/f3d_quad_fixture/quad.obj'
    end if

    call load_obj_ex(trim(obj_path), m, ok, oi)
    call assert_true(ok, 'OBJ fixture loads ok')
    call assert_int_eq(4, m%num_triangles, &
        'OBJ fixture: 4 triangles (1 + 1 + fanned quad 2)')
    call assert_int_eq(2, oi%n_materials, 'OBJ fixture: 2 materials')
    if (oi%n_materials == 2) then
        call assert_true(trim(oi%materials(1)%name) == 'red', &
            'OBJ material 1 is "red"')
        call assert_true(trim(oi%materials(2)%name) == 'blue', &
            'OBJ material 2 is "blue"')
        call assert_real_close(1.0_real64, oi%materials(1)%kd(1), &
            1.0e-12_real64, 'red Kd.r == 1')
        call assert_real_close(1.0_real64, oi%materials(2)%kd(3), &
            1.0e-12_real64, 'blue Kd.b == 1')
        call assert_real_close(0.5_real64, oi%materials(1)%ks(1), &
            1.0e-12_real64, 'red Ks.r == 0.5')
        call assert_true(trim(oi%materials(1)%map_kd) == 'red.png', &
            'red map_Kd == red.png')
        call assert_true(trim(oi%materials(2)%map_kd) == 'blue.png', &
            'blue map_Kd == blue.png')
    end if
    call assert_int_eq(3, oi%n_groups, 'OBJ fixture: 3 group ranges')
    if (oi%n_groups == 3) then
        call assert_true(trim(oi%groups(1)%name) == 'first', &
            'group 1 name == first')
        call assert_true(trim(oi%groups(1)%material_name) == 'red', &
            'group 1 material == red')
        call assert_int_eq(1, oi%groups(1)%tri_count, 'group 1 has 1 tri')
        call assert_true(trim(oi%groups(2)%name) == 'second', &
            'group 2 name == second')
        call assert_int_eq(2, oi%groups(2)%tri_start, 'group 2 starts at tri 2')
        call assert_int_eq(2, oi%groups(3)%tri_count, &
            'group 3 (n-gon fan) has 2 tris')
    end if
    if (m%num_triangles == 4) then
        ! File normals are used (vn 0,0,1), not synthesized.
        call assert_real_close(1.0_real64, m%triangles(1)%vn(1)%z, &
            1.0e-12_real64, 'OBJ tri1 vn(1).z == 1 (file normal)')
        call assert_true(m%triangles(1)%smooth, 'OBJ tri1 is smooth (has vn)')
        ! File UVs: tri1 corners are vt 1,2,3 = (0,0),(1,0),(1,1).
        call assert_real_close(1.0_real64, oi%tri_uv(1, 2, 1), &
            1.0e-12_real64, 'OBJ tri1 corner2 u == 1 (file vt)')
        call assert_real_close(1.0_real64, oi%tri_uv(1, 3, 2), &
            1.0e-12_real64, 'OBJ tri1 corner3 v == 1 (file vt)')
        ! Material colours come from Kd: tri1 red, tri2 blue.
        call assert_int_eq(255, m%triangles(1)%color(1), 'OBJ tri1 R == 255')
        call assert_int_eq(0, m%triangles(1)%color(3), 'OBJ tri1 B == 0')
        call assert_int_eq(255, m%triangles(2)%color(3), 'OBJ tri2 B == 255')
        call assert_int_eq(1, m%triangles(1)%material_id, &
            'OBJ tri1 material_id == 1 (red)')
        call assert_int_eq(2, m%triangles(2)%material_id, &
            'OBJ tri2 material_id == 2 (blue)')
        ! Third group: negative indices + v//vn; verts 5..8 at z=1,
        ! fan tris (5,6,7) and (5,7,8) with vn (0,0,-1).
        call assert_real_close(1.0_real64, m%triangles(3)%v(1)%z, &
            1.0e-12_real64, 'OBJ tri3 v1.z == 1 (negative index resolved)')
        call assert_real_close(-1.0_real64, m%triangles(3)%vn(1)%z, &
            1.0e-12_real64, 'OBJ tri3 vn.z == -1 (v//vn form)')
        call assert_real_close(1.0_real64, m%triangles(4)%v(2)%x, &
            1.0e-12_real64, 'OBJ tri4 v2.x == 1 (fan second triangle)')
        call assert_real_close(0.0_real64, m%triangles(4)%v(3)%x, &
            1.0e-12_real64, 'OBJ tri4 v3.x == 0 (fan second triangle)')
    end if
    call obj_free_info(oi)
    call free_mesh(m)

    ! Plain load_obj still works on the same fixture.
    call load_obj(trim(obj_path), m, ok)
    call assert_true(ok, 'OBJ fixture loads via load_obj')
    call assert_int_eq(4, m%num_triangles, 'load_obj also gives 4 tris')
    call free_mesh(m)

    ! ==================================================================
    ! (b) minimal .glb built in-program
    ! ==================================================================
    call write_quad_bin('/tmp/f3d_test_quad.bin')
    call write_glb('/tmp/f3d_test_quad.glb')
    call load_gltf_ex('/tmp/f3d_test_quad.glb', m, ok, gi)
    call assert_true(ok, 'GLB quad loads ok')
    call assert_int_eq(2, m%num_triangles, 'GLB quad: 2 triangles')
    call check_quad(m, gi, 'GLB')
    call gltf_free_info(gi)
    call free_mesh(m)

    ! ==================================================================
    ! (c) same scene as .gltf + external .bin
    ! ==================================================================
    call write_quad_gltf('/tmp/f3d_test_quad.gltf', 'f3d_test_quad.bin')
    call load_gltf_ex('/tmp/f3d_test_quad.gltf', m, ok, gi)
    call assert_true(ok, 'glTF+bin quad loads ok')
    call assert_int_eq(2, m%num_triangles, 'glTF quad: 2 triangles')
    call check_quad(m, gi, 'glTF')
    call gltf_free_info(gi)
    call free_mesh(m)

    ! ==================================================================
    ! (d) node hierarchy transform: parent T(10,0,0) * Rz(90deg)
    ! ==================================================================
    call write_xform_bin('/tmp/f3d_test_xform.bin')
    call write_xform_gltf('/tmp/f3d_test_xform.gltf')
    call load_gltf('/tmp/f3d_test_xform.gltf', m, ok)
    call assert_true(ok, 'transform glTF loads ok')
    call assert_int_eq(1, m%num_triangles, 'transform glTF: 1 triangle')
    if (m%num_triangles == 1) then
        ! Source (1,0,0),(0,0,0),(0,1,0); Rz90 maps (x,y)->(-y,x),
        ! then + (10,0,0).  Stored winding order is (v0, v2, v1):
        ! (10,1,0), (9,0,0), (10,0,0).
        call assert_real_close(10.0_real64, m%triangles(1)%v(1)%x, &
            1.0e-9_real64, 'xform v1.x == 10')
        call assert_real_close(1.0_real64, m%triangles(1)%v(1)%y, &
            1.0e-9_real64, 'xform v1.y == 1 (rotated)')
        call assert_real_close(9.0_real64, m%triangles(1)%v(2)%x, &
            1.0e-9_real64, 'xform v2.x == 9')
        call assert_real_close(0.0_real64, m%triangles(1)%v(2)%y, &
            1.0e-9_real64, 'xform v2.y == 0')
        call assert_real_close(10.0_real64, m%triangles(1)%v(3)%x, &
            1.0e-9_real64, 'xform v3.x == 10')
    end if
    call free_mesh(m)

    ! ==================================================================
    ! (e) 100k-triangle OBJ timing smoke check
    ! ==================================================================
    call get_environment_variable('HOME', home)
    scratch = trim(home) // '/workspace/.scratch-f3d'
    call execute_command_line('mkdir -p ' // trim(scratch), &
        exitstat=status)
    call assert_int_eq(0, status, 'scratch dir created')
    call write_big_obj(trim(scratch) // '/big_grid.obj')
    call cpu_time(t0)
    call load_obj(trim(scratch) // '/big_grid.obj', m, ok)
    call cpu_time(t1)
    elapsed = t1 - t0
    write(*, '(A, F8.3, A)') '100k-tri OBJ load time: ', elapsed, ' s'
    call assert_true(ok, 'big grid OBJ loads ok')
    call assert_int_eq(100352, m%num_triangles, &
        'big grid: 224*224*2 == 100352 triangles')
    call assert_true(elapsed < 5.0_real64, &
        'big grid load < 5 s (smoke bound; phase target < 1 s)')
    call free_mesh(m)
    call execute_command_line('rm -f ' // trim(scratch) // &
        '/big_grid.obj; rmdir ' // trim(scratch) // ' 2>/dev/null')

    call test_summary()

contains

    ! Shared assertions for the quad scene (b)/(c): stored winding
    ! order is (i1, i3, i2), so tri1 = verts (0,2,1), tri2 = (0,3,2).
    subroutine check_quad(mm, gg, tag)
        type(Mesh), intent(in) :: mm
        type(GltfInfo), intent(in) :: gg
        character(len=*), intent(in) :: tag
        if (mm%num_triangles /= 2) return
        call assert_real_close(0.0_real64, mm%triangles(1)%v(1)%x, &
            1.0e-12_real64, tag // ' tri1 v1.x == 0')
        call assert_real_close(1.0_real64, mm%triangles(1)%v(2)%x, &
            1.0e-12_real64, tag // ' tri1 v2.x == 1 (source v2)')
        call assert_real_close(1.0_real64, mm%triangles(1)%v(2)%y, &
            1.0e-12_real64, tag // ' tri1 v2.y == 1 (source v2)')
        call assert_real_close(1.0_real64, mm%triangles(1)%v(3)%x, &
            1.0e-12_real64, tag // ' tri1 v3.x == 1 (source v1)')
        call assert_real_close(0.0_real64, mm%triangles(1)%v(3)%y, &
            1.0e-12_real64, tag // ' tri1 v3.y == 0 (source v1)')
        call assert_real_close(1.0_real64, mm%triangles(2)%v(2)%y, &
            1.0e-12_real64, tag // ' tri2 v2.y == 1 (source v3)')
        ! File normals (0,0,1) on every corner, smooth.
        call assert_real_close(1.0_real64, mm%triangles(1)%vn(1)%z, &
            1.0e-12_real64, tag // ' tri1 vn.z == 1 (file normal)')
        call assert_true(mm%triangles(1)%smooth, tag // ' tri1 smooth')
        ! UVs in stored corner order: tri1 = uv(0), uv(2), uv(1).
        call assert_true(gg%has_uv, tag // ' has_uv')
        call assert_real_close(1.0_real64, gg%tri_uv(1, 2, 1), &
            1.0e-12_real64, tag // ' tri1 corner2 u == 1')
        call assert_real_close(1.0_real64, gg%tri_uv(1, 2, 2), &
            1.0e-12_real64, tag // ' tri1 corner2 v == 1')
        call assert_real_close(1.0_real64, gg%tri_uv(1, 3, 1), &
            1.0e-12_real64, tag // ' tri1 corner3 u == 1')
        call assert_real_close(0.0_real64, gg%tri_uv(1, 3, 2), &
            1.0e-12_real64, tag // ' tri1 corner3 v == 0')
        call assert_real_close(1.0_real64, gg%tri_uv(2, 2, 2), &
            1.0e-12_real64, tag // ' tri2 corner2 v == 1')
    end subroutine check_quad

    ! Quad binary: POSITION (4xVEC3) @0, NORMAL (4xVEC3) @48,
    ! TEXCOORD_0 (4xVEC2) @96, indices (6xuint16) @128.  140 bytes.
    subroutine write_quad_bin(path)
        character(len=*), intent(in) :: path
        integer :: uu
        open(newunit=uu, file=path, status='replace', action='write', &
             access='stream', form='unformatted')
        write(uu) 0.0_real32, 0.0_real32, 0.0_real32
        write(uu) 1.0_real32, 0.0_real32, 0.0_real32
        write(uu) 1.0_real32, 1.0_real32, 0.0_real32
        write(uu) 0.0_real32, 1.0_real32, 0.0_real32
        write(uu) 0.0_real32, 0.0_real32, 1.0_real32
        write(uu) 0.0_real32, 0.0_real32, 1.0_real32
        write(uu) 0.0_real32, 0.0_real32, 1.0_real32
        write(uu) 0.0_real32, 0.0_real32, 1.0_real32
        write(uu) 0.0_real32, 0.0_real32
        write(uu) 1.0_real32, 0.0_real32
        write(uu) 1.0_real32, 1.0_real32
        write(uu) 0.0_real32, 1.0_real32
        write(uu) 0_int16, 1_int16, 2_int16, 0_int16, 2_int16, 3_int16
        close(uu)
    end subroutine write_quad_bin

    subroutine write_quad_json(uu, uri_line)
        integer, intent(in) :: uu
        character(len=*), intent(in) :: uri_line
        write(uu, '(A)') '{'
        write(uu, '(A)') '"asset": {"version": "2.0"},'
        write(uu, '(A)') '"scene": 0,'
        write(uu, '(A)') '"scenes": [{"nodes": [0]}],'
        write(uu, '(A)') '"nodes": [{"mesh": 0}],'
        write(uu, '(A)') '"meshes": [{"primitives": [{'
        write(uu, '(A)') '"attributes": {"POSITION": 0, "NORMAL": 1, ' // &
            '"TEXCOORD_0": 2}, "indices": 3}]}],'
        write(uu, '(A)') '"buffers": [{' // trim(uri_line) // '}],'
        write(uu, '(A)') '"bufferViews": ['
        write(uu, '(A)') '{"buffer": 0, "byteOffset": 0, "byteLength": 48},'
        write(uu, '(A)') '{"buffer": 0, "byteOffset": 48, "byteLength": 48},'
        write(uu, '(A)') '{"buffer": 0, "byteOffset": 96, "byteLength": 32},'
        write(uu, '(A)') '{"buffer": 0, "byteOffset": 128, "byteLength": 12}],'
        write(uu, '(A)') '"accessors": ['
        write(uu, '(A)') '{"bufferView": 0, "componentType": 5126, ' // &
            '"count": 4, "type": "VEC3"},'
        write(uu, '(A)') '{"bufferView": 1, "componentType": 5126, ' // &
            '"count": 4, "type": "VEC3"},'
        write(uu, '(A)') '{"bufferView": 2, "componentType": 5126, ' // &
            '"count": 4, "type": "VEC2"},'
        write(uu, '(A)') '{"bufferView": 3, "componentType": 5123, ' // &
            '"count": 6, "type": "SCALAR"}]'
        write(uu, '(A)') '}'
    end subroutine write_quad_json

    subroutine write_quad_gltf(path, bin_name)
        character(len=*), intent(in) :: path, bin_name
        integer :: uu
        open(newunit=uu, file=path, status='replace', action='write')
        call write_quad_json(uu, '"byteLength": 140, "uri": "' // &
            trim(bin_name) // '"')
        close(uu)
    end subroutine write_quad_gltf

    ! Build the .glb: header, JSON chunk (space-padded to 4), BIN
    ! chunk (zero-padded to 4) whose bytes are the quad binary.
    subroutine write_glb(path)
        character(len=*), intent(in) :: path
        integer :: uu, ju, ios, fsize, k
        integer(int32) :: magic, jtype, btype
        character(len=4096) :: json
        integer :: jlen, jpad, blen, bpad, total
        integer(int8), allocatable :: binbytes(:)
        ! Render the JSON into a scratch text file, then read it back
        ! so its exact length is known for the chunk header.
        open(newunit=ju, file='/tmp/f3d_test_quad_glb.json', &
             status='replace', action='write')
        call write_quad_json(ju, '"byteLength": 140')
        close(ju)
        inquire(file='/tmp/f3d_test_quad_glb.json', size=fsize)
        jlen = fsize
        ! The text writer appends a newline per record; account for
        ! the records written (20 lines) -- simpler: read the file
        ! back and trim trailing newlines by scanning for '}'.
        open(newunit=ju, file='/tmp/f3d_test_quad_glb.json', &
             status='old', action='read', access='stream', &
             form='unformatted')
        read(ju, iostat=ios) json(1:jlen)
        close(ju)
        do k = jlen, 1, -1
            if (json(k:k) == '}') then
                jlen = k
                exit
            end if
        end do
        jpad = mod(4 - mod(jlen, 4), 4)
        blen = 140
        bpad = mod(4 - mod(blen, 4), 4)
        total = 12 + 8 + jlen + jpad + 8 + blen + bpad
        magic = transfer('glTF', 0_int32)
        jtype = transfer('JSON', 0_int32)
        btype = int(z'004E4942', int32)  ! 'BIN\0' little-endian
        ! Read the quad .bin bytes.
        allocate(binbytes(blen))
        open(newunit=ju, file='/tmp/f3d_test_quad.bin', status='old', &
             action='read', access='stream', form='unformatted')
        read(ju) binbytes
        close(ju)
        open(newunit=uu, file=path, status='replace', action='write', &
             access='stream', form='unformatted')
        write(uu) magic, 2_int32, int(total, int32)
        write(uu) int(jlen + jpad, int32), jtype
        write(uu) json(1:jlen)
        do k = 1, jpad
            write(uu) ' '
        end do
        write(uu) int(blen + bpad, int32), btype
        write(uu) binbytes
        do k = 1, bpad
            write(uu) 0_int8
        end do
        close(uu)
        deallocate(binbytes)
    end subroutine write_glb

    ! One-triangle binary for the transform test: 3 positions + 3
    ! uint16 indices = 42 bytes.
    subroutine write_xform_bin(path)
        character(len=*), intent(in) :: path
        integer :: uu
        open(newunit=uu, file=path, status='replace', action='write', &
             access='stream', form='unformatted')
        write(uu) 1.0_real32, 0.0_real32, 0.0_real32
        write(uu) 0.0_real32, 0.0_real32, 0.0_real32
        write(uu) 0.0_real32, 1.0_real32, 0.0_real32
        write(uu) 0_int16, 1_int16, 2_int16
        close(uu)
    end subroutine write_xform_bin

    subroutine write_xform_gltf(path)
        character(len=*), intent(in) :: path
        integer :: uu
        open(newunit=uu, file=path, status='replace', action='write')
        write(uu, '(A)') '{'
        write(uu, '(A)') '"asset": {"version": "2.0"},'
        write(uu, '(A)') '"scene": 0,'
        write(uu, '(A)') '"scenes": [{"nodes": [0]}],'
        write(uu, '(A)') '"nodes": ['
        write(uu, '(A)') '{"translation": [10.0, 0.0, 0.0], ' // &
            '"rotation": [0.0, 0.0, 0.7071067811865476, ' // &
            '0.7071067811865476], "children": [1]},'
        write(uu, '(A)') '{"mesh": 0}],'
        write(uu, '(A)') '"meshes": [{"primitives": [{'
        write(uu, '(A)') '"attributes": {"POSITION": 0}, "indices": 1}]}],'
        write(uu, '(A)') '"buffers": [{"byteLength": 42, ' // &
            '"uri": "f3d_test_xform.bin"}],'
        write(uu, '(A)') '"bufferViews": ['
        write(uu, '(A)') '{"buffer": 0, "byteOffset": 0, "byteLength": 36},'
        write(uu, '(A)') '{"buffer": 0, "byteOffset": 36, "byteLength": 6}],'
        write(uu, '(A)') '"accessors": ['
        write(uu, '(A)') '{"bufferView": 0, "componentType": 5126, ' // &
            '"count": 3, "type": "VEC3"},'
        write(uu, '(A)') '{"bufferView": 1, "componentType": 5123, ' // &
            '"count": 3, "type": "SCALAR"}]'
        write(uu, '(A)') '}'
        close(uu)
    end subroutine write_xform_gltf

    ! 225x225 vertex grid -> 224x224 quads -> 100352 triangles.
    subroutine write_big_obj(path)
        character(len=*), intent(in) :: path
        integer :: uu, i, j, a, b, c, d
        integer, parameter :: N = 225
        open(newunit=uu, file=path, status='replace', action='write')
        do j = 0, N - 1
            do i = 0, N - 1
                write(uu, '(A, I0, A, I0, A)') 'v ', i, '.0 ', j, '.0 0.0'
            end do
        end do
        do j = 0, N - 2
            do i = 0, N - 2
                a = j * N + i + 1
                b = a + 1
                c = a + N
                d = c + 1
                write(uu, '(A, I0, A, I0, A, I0)') 'f ', a, ' ', b, ' ', d
                write(uu, '(A, I0, A, I0, A, I0)') 'f ', a, ' ', d, ' ', c
            end do
        end do
        close(uu)
    end subroutine write_big_obj

end program test_loaders
