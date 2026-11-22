! test_gltf_loader.f90 -- tests for gltf_loader (Wave B seat B64):
! external-.bin fixture, data-URI (base64) buffer, missing/malformed
! file robustness, and the committed canonical fixture when locatable.
!
! Like test_texture.f90, the fixtures are generated in-code (under
! /tmp) because run_tests.py executes test programs from a temporary
! working directory, so relative fixture paths cannot be relied on.
! The canonical sample lives in tests/fortran/fixtures/triangle.gltf
! (+ triangle.bin); when it can be found relative to the cwd it is
! loaded and checked too.
program test_gltf_loader
    use, intrinsic :: iso_fortran_env, only: real32, int16
    use math_3d
    use mesh_3d
    use gltf_loader
    use test_assert
    implicit none

    type(Mesh) :: m
    logical :: ok, exists
    integer :: unit, i
    character(len=*), parameter :: dir = '/tmp/'
    character(len=*), parameter :: bin_path  = dir // 'test_gltf_loader_triangle.bin'
    character(len=*), parameter :: ext_path  = dir // 'test_gltf_loader_triangle_ext.gltf'
    character(len=*), parameter :: uri_path  = dir // 'test_gltf_loader_triangle_uri.gltf'
    character(len=*), parameter :: bad_path  = dir // 'test_gltf_loader_bad.gltf'
    ! base64 of the 42 fixture bytes: 9 float32 positions
    ! (0,0,0) (1,0,0) (0,1,0) + 3 uint16 indices (0,1,2).
    character(len=*), parameter :: b64 = &
        'AAAAAAAAAAAAAAAAAACAPwAAAAAAAAAAAAAAAAAAgD8AAAAAAAABAAIA'
    character(len=256) :: candidates(3)
    character(len=256) :: found_path

    ! ---- generate the shared .bin: positions then indices ----
    open(newunit=unit, file=bin_path, status='replace', action='write', &
         access='stream', form='unformatted')
    write(unit) 0.0_real32, 0.0_real32, 0.0_real32   ! v0 (0,0,0)
    write(unit) 1.0_real32, 0.0_real32, 0.0_real32   ! v1 (1,0,0)
    write(unit) 0.0_real32, 1.0_real32, 0.0_real32   ! v2 (0,1,0)
    write(unit) 0_int16, 1_int16, 2_int16            ! indices 0,1,2
    close(unit)

    ! ---- external-buffer .gltf (buffer uri = the .bin file name) ----
    open(newunit=unit, file=ext_path, status='replace', action='write')
    write(unit, '(A)') '{'
    write(unit, '(A)') '  "asset": {"version": "2.0"},'
    write(unit, '(A)') '  "buffers": [{"byteLength": 42, "uri": "' // &
                       'test_gltf_loader_triangle.bin"}],'
    write(unit, '(A)') '  "bufferViews": ['
    write(unit, '(A)') '    {"buffer": 0, "byteOffset": 0, "byteLength": 36},'
    write(unit, '(A)') '    {"buffer": 0, "byteOffset": 36, "byteLength": 6}],'
    write(unit, '(A)') '  "accessors": ['
    write(unit, '(A)') '    {"bufferView": 0, "componentType": 5126, ' // &
                       '"count": 3, "type": "VEC3"},'
    write(unit, '(A)') '    {"bufferView": 1, "componentType": 5123, ' // &
                       '"count": 3, "type": "SCALAR"}],'
    write(unit, '(A)') '  "meshes": [{"primitives": [{' // &
                       '"attributes": {"POSITION": 0}, "indices": 1}]}]'
    write(unit, '(A)') '}'
    close(unit)

    call load_gltf(ext_path, m, ok)
    call assert_true(ok, 'external .bin fixture loads ok')
    call assert_int_eq(1, m%num_triangles, 'external fixture num_triangles == 1')
    if (m%num_triangles == 1) then
        call assert_real_close(0.0_dp, m%triangles(1)%v(1)%x, 1.0e-12_dp, 'v0.x == 0')
        call assert_real_close(0.0_dp, m%triangles(1)%v(1)%y, 1.0e-12_dp, 'v0.y == 0')
        call assert_real_close(0.0_dp, m%triangles(1)%v(1)%z, 1.0e-12_dp, 'v0.z == 0')
        ! Winding conversion: indices (0,1,2) are stored as (0,2,1),
        ! so v(2) is the source v2 (0,1,0) and v(3) is source v1 (1,0,0).
        call assert_real_close(0.0_dp, m%triangles(1)%v(2)%x, 1.0e-12_dp, 'v2.x == 0 (stored 2nd)')
        call assert_real_close(1.0_dp, m%triangles(1)%v(2)%y, 1.0e-12_dp, 'v2.y == 1 (stored 2nd)')
        call assert_real_close(0.0_dp, m%triangles(1)%v(2)%z, 1.0e-12_dp, 'v2.z == 0 (stored 2nd)')
        call assert_real_close(1.0_dp, m%triangles(1)%v(3)%x, 1.0e-12_dp, 'v1.x == 1 (stored 3rd)')
        call assert_real_close(0.0_dp, m%triangles(1)%v(3)%y, 1.0e-12_dp, 'v1.y == 0 (stored 3rd)')
        call assert_real_close(0.0_dp, m%triangles(1)%v(3)%z, 1.0e-12_dp, 'v1.z == 0 (stored 3rd)')
        ! Stored winding (0,0,0)->(0,1,0)->(1,0,0) gives a -Z normal
        ! (flipped from the raw glTF +Z, as expected for the engine
        ! convention); assert magnitudes so the check is winding-sign
        ! agnostic.
        call assert_real_close(0.0_dp, abs(m%triangles(1)%normal%x), &
            1.0e-12_dp, '|normal.x| == 0')
        call assert_real_close(0.0_dp, abs(m%triangles(1)%normal%y), &
            1.0e-12_dp, '|normal.y| == 0')
        call assert_real_close(1.0_dp, abs(m%triangles(1)%normal%z), &
            1.0e-12_dp, '|normal.z| == 1')
        call assert_int_eq(255, m%triangles(1)%color(1), 'colour R == 255 (white)')
        call assert_int_eq(255, m%triangles(1)%color(2), 'colour G == 255 (white)')
        call assert_int_eq(255, m%triangles(1)%color(3), 'colour B == 255 (white)')
    end if
    call free_mesh(m)

    ! ---- data-URI (base64) variant of the same triangle ----
    open(newunit=unit, file=uri_path, status='replace', action='write')
    write(unit, '(A)') '{'
    write(unit, '(A)') '  "asset": {"version": "2.0"},'
    write(unit, '(A)') '  "buffers": [{"byteLength": 42, "uri": ' // &
                       '"data:application/octet-stream;base64,' // b64 // '"}],'
    write(unit, '(A)') '  "bufferViews": ['
    write(unit, '(A)') '    {"buffer": 0, "byteOffset": 0, "byteLength": 36},'
    write(unit, '(A)') '    {"buffer": 0, "byteOffset": 36, "byteLength": 6}],'
    write(unit, '(A)') '  "accessors": ['
    write(unit, '(A)') '    {"bufferView": 0, "componentType": 5126, ' // &
                       '"count": 3, "type": "VEC3"},'
    write(unit, '(A)') '    {"bufferView": 1, "componentType": 5123, ' // &
                       '"count": 3, "type": "SCALAR"}],'
    write(unit, '(A)') '  "meshes": [{"primitives": [{' // &
                       '"attributes": {"POSITION": 0}, "indices": 1}]}]'
    write(unit, '(A)') '}'
    close(unit)

    call load_gltf(uri_path, m, ok)
    call assert_true(ok, 'data-URI fixture loads ok')
    call assert_int_eq(1, m%num_triangles, 'data-URI num_triangles == 1')
    if (m%num_triangles == 1) then
        ! Winding conversion: stored order is (0,2,1), so v(2) is
        ! source v2 and v(3) is source v1.
        call assert_real_close(1.0_dp, m%triangles(1)%v(2)%y, 1.0e-12_dp, &
            'data-URI v2.y == 1 (stored 2nd)')
        call assert_real_close(1.0_dp, m%triangles(1)%v(3)%x, 1.0e-12_dp, &
            'data-URI v1.x == 1 (stored 3rd)')
        call assert_real_close(1.0_dp, abs(m%triangles(1)%normal%z), &
            1.0e-12_dp, 'data-URI |normal.z| == 1')
    end if
    call free_mesh(m)

    ! ---- missing file: ok = .false., 0 triangles, no crash ----
    call load_gltf('/tmp/test_gltf_loader_does_not_exist.gltf', m, ok)
    call assert_false(ok, 'missing file gives ok=.false.')
    call assert_int_eq(0, m%num_triangles, 'missing file gives 0 triangles')

    ! ---- malformed file: ok = .false., 0 triangles, no crash ----
    open(newunit=unit, file=bad_path, status='replace', action='write')
    write(unit, '(A)') 'this is not json at all'
    close(unit)
    call load_gltf(bad_path, m, ok)
    call assert_false(ok, 'malformed file gives ok=.false.')
    call assert_int_eq(0, m%num_triangles, 'malformed file gives 0 triangles')
    call free_mesh(m)

    ! ---- committed canonical fixture, when locatable from cwd ----
    candidates(1) = 'tests/fortran/fixtures/triangle.gltf'
    candidates(2) = '../tests/fortran/fixtures/triangle.gltf'
    candidates(3) = '../../tests/fortran/fixtures/triangle.gltf'
    found_path = ''
    do i = 1, size(candidates)
        inquire(file=trim(candidates(i)), exist=exists)
        if (exists) then
            found_path = candidates(i)
            exit
        end if
    end do
    if (len_trim(found_path) > 0) then
        call load_gltf(trim(found_path), m, ok)
        call assert_true(ok, 'committed fixture loads ok')
        call assert_int_eq(1, m%num_triangles, &
            'committed fixture num_triangles == 1')
        if (m%num_triangles == 1) then
            ! Winding conversion: stored order is (0,2,1), so the
            ! source v1 (1,0,0) is stored third.
            call assert_real_close(1.0_dp, m%triangles(1)%v(3)%x, &
                1.0e-12_dp, 'committed fixture v1.x == 1 (stored 3rd)')
            call assert_real_close(1.0_dp, abs(m%triangles(1)%normal%z), &
                1.0e-12_dp, 'committed fixture |normal.z| == 1')
        end if
        call free_mesh(m)
    end if

    call test_summary()

end program test_gltf_loader
