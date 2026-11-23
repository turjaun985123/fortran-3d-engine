! test_scene_growth.f90 -- S2 (v3.0 Phase 0): scene_load storage
! grows by capacity doubling (counts in the Scene's n_* fields,
! capacity in cap_*), and is trimmed back to exact size before
! scene_load returns, so size(array) == count for outside readers
! (key_eval reads size(track%keys); main reads the Scene arrays).
! Loads a generated scene with enough elements of every append_*
! kind to force several doublings and checks counts, capacities,
! contents and keyframe evaluation on the result.
program test_scene_growth
    use math_3d
    use scene_3d
    use keyframe_3d, only: key_eval
    use test_assert
    implicit none

    type(Scene) :: sc
    logical :: ok
    character(len=256) :: errmsg
    character(len=*), parameter :: path = '/tmp/test_scene_growth.scene'
    integer :: u, i
    real(dp) :: k_pos(3), k_rot(3), k_scale
    character(len=16) :: name

    ! ---- generate a scene: 100 objects, 20 anims, 10 sprites,
    ! ---- 10 texts, 5 particle systems, 1 track with 20 keys ----
    open(newunit=u, file=path, status='replace', action='write')
    write(u, '(A)') 'forge3d-scene 1'
    write(u, '(A)') 'size 64 48'
    write(u, '(A)') 'bg 25 25 35'
    write(u, '(A)') 'camera 3 2.5 4 0 0 0 0 1 0 60 0.1 100'
    write(u, '(A)') 'light directional -0.5 -1 -0.7 255 255 255 1.0'
    write(u, '(A)') 'light ambient 0.25'
    write(u, '(A)') 'frames 1'
    write(u, '(A)') 'output growth.ppm'
    do i = 1, 100
        write(name, '(A, I0)') 'obj', i - 1
        write(u, '(A, I0, A)') &
            'object cube ' // trim(name) // &
            ' lambert 200 80 80 ', i - 1, ' 0 0 0 0 0 1 1 1 1 -1 -1 0'
    end do
    do i = 1, 20
        write(u, '(A, I0, A)') 'anim rotate obj', i - 1, &
            ' y 1.0 2.0 30 linear forever'
    end do
    do i = 1, 10
        write(u, '(A, I0, A)') 'sprite spr', i - 1, ' 0 0 0 1 255 0 0'
        write(u, '(A, I0, A)') 'text txt', i - 1, &
            ' 0 0 0 1 0 255 0 hello'
    end do
    do i = 1, 5
        write(u, '(A, I0, A)') 'particles prt', i - 1, &
            ' 0 0 0 10 1.0 1.0 0.1 255 255 255 0.5 0.0 42'
    end do
    write(u, '(A)') 'keys obj0 19 once 20'
    do i = 1, 20
        write(u, '(A, I0, A, I0, A)') 'key ', i - 1, '.0 ', &
            2 * (i - 1), '.0 0 0 0 0 0 1 linear'
    end do
    close(u)

    call scene_load(path, sc, ok, errmsg)
    call assert_true(ok, 'scene_load of generated growth scene succeeds')

    ! ---- counts and trimmed capacities ----
    call assert_int_eq(100, sc%n_objects, 'growth scene has 100 objects')
    call assert_int_eq(100, sc%cap_objects, &
        'objects trimmed: cap_objects == n_objects after load')
    call assert_int_eq(100, size(sc%objects), &
        'objects trimmed: size(objects) == 100 after load')
    call assert_int_eq(20, sc%n_anims, 'growth scene has 20 anims')
    call assert_int_eq(20, size(sc%anims), &
        'anims trimmed: size(anims) == 20 after load')
    call assert_int_eq(10, sc%n_sprites, 'growth scene has 10 sprites')
    call assert_int_eq(10, size(sc%sprites), &
        'sprites trimmed: size(sprites) == 10 after load')
    call assert_int_eq(10, sc%n_texts, 'growth scene has 10 texts')
    call assert_int_eq(10, size(sc%texts), &
        'texts trimmed: size(texts) == 10 after load')
    call assert_int_eq(5, sc%n_parts, 'growth scene has 5 particle systems')
    call assert_int_eq(5, size(sc%parts), &
        'parts trimmed: size(parts) == 5 after load')
    call assert_int_eq(1, sc%n_tracks, 'growth scene has 1 track')
    call assert_int_eq(20, size(sc%tracks(1)%keys), &
        'keys trimmed: size(track keys) == 20 after load')

    ! ---- contents survived the growth copies, in order ----
    call assert_true(trim(sc%objects(1)%name) == 'obj0', &
        'first object is obj0')
    call assert_true(trim(sc%objects(100)%name) == 'obj99', &
        'last object is obj99')
    call assert_real_close(99.0_dp, sc%objects(100)%pos%x, 1.0e-12_dp, &
        'last object pos.x == 99 (its object-line x)')
    call assert_int_eq(100, scene_find_object(sc, 'obj99'), &
        'scene_find_object finds obj99 at index 100')
    call assert_int_eq(0, scene_find_object(sc, 'obj100'), &
        'scene_find_object returns 0 for a missing object')

    ! ---- keyframe evaluation sees exactly the 20 loaded keys ----
    call key_eval(sc%tracks(1), 5.5_dp, k_pos, k_rot, k_scale)
    call assert_real_close(11.0_dp, k_pos(1), 1.0e-12_dp, &
        'key_eval at t=5.5 interpolates pos.x == 11')
    call key_eval(sc%tracks(1), 100.0_dp, k_pos, k_rot, k_scale)
    call assert_real_close(38.0_dp, k_pos(1), 1.0e-12_dp, &
        'key_eval past the end clamps to the last key (pos.x == 38)')

    call scene_free(sc)
    call assert_int_eq(0, sc%n_objects, 'scene_free resets n_objects')
    call assert_int_eq(0, sc%cap_objects, 'scene_free resets cap_objects')

    call test_summary()

end program test_scene_growth
