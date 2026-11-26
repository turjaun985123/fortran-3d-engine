! test_timeline_ir.f90 -- Animation Compiler Wave 2, slice A4:
! the typed Timeline IR reader (timeline_ir_3d's read_timeline,
! ANIM-PLAN section 3 / ADR-5) against hand-written .timeline.json
! documents.
!
! Coverage: a valid full document in the 3.5 excerpt shape (with
! "plugin" on characters, unknown extra keys at several levels);
! the committed fixture tests/fixtures/sample.timeline.json;
! missing format -> error; wrong format -> error naming the value
! found; wrong ir_version -> error naming the version; missing
! ir_version -> error; unknown track kind skipped WITH a recorded
! diagnostic; unknown ease -> linear + diagnostic; end < start
! rejected (track), end <= start rejected (dialogue), a scene span
! running past the timeline duration rejected; missing fps
! rejected; missing file and malformed JSON rejected; dialogue
! text compared byte-for-byte including a UTF-8 (Bengali + em
! dash) string.
!
! Fixture documents are written as strings into a scratch dir
! (.timeline-ir-test-scratch under the repo root, removed at the
! end), in the style of test_scene_json.f90.  The program is
! auto-discovered by tests/run_tests.sh (Fortran layer).
program test_timeline_ir
    use, intrinsic :: iso_fortran_env, only: real64
    use timeline_ir_3d
    use test_assert
    implicit none

    character(len=512) :: env, repo, scratch
    integer :: st

    call get_environment_variable('FORGE3D_ROOT', env, status=st)
    if (st == 0 .and. len_trim(env) > 0) then
        repo = trim(env)
    else
        repo = '.'
    end if
    scratch = trim(repo) // '/.timeline-ir-test-scratch'
    call execute_command_line('rm -rf ' // trim(scratch) // &
        ' && mkdir -p ' // trim(scratch), exitstat=st)
    call assert_true(st == 0, 'scratch dir created')

    call check_valid()
    call check_fixture()
    call check_gates()
    call check_skips_and_ease()
    call check_sanity()

    call execute_command_line('rm -rf ' // trim(scratch), &
                              exitstat=st)
    call test_summary()

contains

    function spath(fname) result(p)
        character(len=*), intent(in) :: fname
        character(len=1024) :: p
        p = trim(scratch) // '/' // trim(fname)
    end function spath

    subroutine write_doc(fname, text)
        character(len=*), intent(in) :: fname, text
        integer :: u, ios
        open(newunit=u, file=trim(spath(fname)), status='replace', &
             action='write', iostat=ios)
        call assert_true(ios == 0, 'fixture written: ' // trim(fname))
        if (ios /= 0) return
        write(u, '(A)') text
        close(u)
    end subroutine write_doc

    logical function has(hay, needle) result(r)
        character(len=*), intent(in) :: hay, needle
        r = index(hay, needle) > 0
    end function has

    function kv_lookup(pairs, n, key) result(val)
        type(tl_kv), intent(in) :: pairs(:)
        integer, intent(in) :: n
        character(len=*), intent(in) :: key
        character(len=:), allocatable :: val
        integer :: i
        allocate(character(len=0) :: val)
        do i = 1, n
            if (allocated(pairs(i)%key)) then
                if (pairs(i)%key == key) then
                    deallocate(val)
                    val = pairs(i)%value
                    return
                end if
            end if
        end do
    end function kv_lookup

    logical function notes_have(tl, needle) result(r)
        type(tl_timeline), intent(in) :: tl
        character(len=*), intent(in) :: needle
        integer :: i
        r = .false.
        do i = 1, tl%n_notes
            if (index(tl%notes(i), needle) > 0) r = .true.
        end do
    end function notes_have

    ! ---------------------------------------------------------------
    ! The valid full document (3.5 excerpt shape + plugin + unknown
    ! extra keys, which must be tolerated).
    ! ---------------------------------------------------------------
    subroutine check_valid()
        type(tl_timeline) :: tl
        logical :: ok
        character(len=1024) :: err
        character(len=:), allocatable :: doc

        doc = &
        '{"format":"forge3d-timeline","ir_version":1,' // &
        '"name":"gate-scene","fps":{"num":24,"den":1},' // &
        '"duration_frames":48,"future_top":{"x":1},' // &
        '"generator":{"tool":"f3dc","version":"4.0",' // &
        '"source":"gate.f3d"},' // &
        '"characters":[' // &
        '{"id":"mira","name":"Mira","color":[90,140,220],' // &
        '"plugin":"stickman","future_field":{"y":2},' // &
        '"rig":{"kind":"stick","topology":"humanoid11"},' // &
        '"voice":{"speaker":"Mira"}},' // &
        '{"id":"finn","name":"Finn","color":[230,170,60],' // &
        '"plugin":"stickman",' // &
        '"rig":{"kind":"stick","topology":"humanoid11"},' // &
        '"voice":{"speaker":"Finn"}}],' // &
        '"scenes":[{"id":"s1","name":"gate-one",' // &
        '"scene_file":"gate-gate-one.json","scene_ir_version":1,' // &
        '"start_frame":0,"duration_frames":48,' // &
        '"bindings":{"mira":"mira_body","finn":"finn_body"}}],' // &
        '"tracks":[' // &
        '{"kind":"action","scene":"s1","character":"mira",' // &
        '"action":"wave","start_frame":24,"end_frame":48,' // &
        '"params":{"arm":"right","cycles":2},"zzz":[1,2],' // &
        '"keys":[' // &
        '{"frame":24,"channel":"arm.r.upper","value_deg":-10.0,' // &
        '"ease":"linear"},' // &
        '{"frame":36,"channel":"arm.r.upper","value_deg":-150.0,' // &
        '"ease":"smooth"},' // &
        '{"frame":48,"channel":"arm.r.upper","value_deg":-10.0,' // &
        '"ease":"smooth"}]},' // &
        '{"kind":"pose_keys","scene":"s1","character":"finn",' // &
        '"keys":[' // &
        '{"frame":0,"pos":[1.5,0,0],"rot_deg":[0,-20,0],' // &
        '"scale":1.0,"ease":"linear"},' // &
        '{"frame":48,"pos":[1.5,0,0],"rot_deg":[0,-35,0],' // &
        '"scale":1.0,"ease":"smooth"}]},' // &
        '{"kind":"camera","scene":"s1","keys":[' // &
        '{"frame":0,"pos":[5,3,7],"target":[0,0,0],"fov":60,' // &
        '"ease":"linear"},' // &
        '{"frame":48,"pos":[3,2,4],"target":[0,0.5,0],"fov":50,' // &
        '"ease":"smooth"}]}],' // &
        '"dialogue":[{"id":"d1","scene":"s1","start_frame":12,' // &
        '"end_frame":48,"speaker":"mira",' // &
        '"text":"Finn — হ্যালো, over here!"}],' // &
        '"markers":[{"frame":24,"name":"the wave","kind":"beat"}]}'
        call write_doc('valid.timeline.json', doc)
        deallocate(doc)

        call read_timeline(spath('valid.timeline.json'), tl, ok, err)
        if (.not. ok) write(*, '(A, A)') '  error: ', trim(err)
        call assert_true(ok, 'valid: read ok')
        if (.not. ok) return
        call assert_true(tl%name == 'gate-scene', 'valid: name')
        call assert_int_eq(tl%fps_num, 24, 'valid: fps num')
        call assert_int_eq(tl%fps_den, 1, 'valid: fps den')
        call assert_int_eq(tl%duration_frames, 48, 'valid: duration')
        call assert_true(tl%gen_tool == 'f3dc', 'valid: generator')
        call assert_int_eq(tl%n_skipped_tracks, 0, 'valid: no skips')
        call assert_int_eq(tl%n_notes, 0, 'valid: no notes')

        call assert_int_eq(tl%n_characters, 2, 'valid: 2 characters')
        call assert_true(tl%characters(1)%id == 'mira', &
                         'valid: char 1 id')
        call assert_true(tl%characters(1)%plugin == 'stickman', &
                         'valid: char 1 plugin id')
        call assert_true(tl%characters(1)%rig_kind == 'stick', &
                         'valid: char 1 rig kind')
        call assert_true(tl%characters(1)%rig_topology == &
                         'humanoid11', 'valid: char 1 rig topology')
        call assert_true(tl%characters(1)%has_color, &
                         'valid: char 1 has color')
        call assert_int_eq(tl%characters(1)%color(1), 90, &
                           'valid: char 1 color r')
        call assert_int_eq(tl%characters(1)%color(3), 220, &
                           'valid: char 1 color b')
        call assert_true(tl%characters(1)%voice_speaker == 'Mira', &
                         'valid: char 1 voice speaker')
        call assert_true(tl%characters(2)%name == 'Finn', &
                         'valid: char 2 name')

        call assert_int_eq(tl%n_scenes, 1, 'valid: 1 scene span')
        call assert_true(tl%scenes(1)%scene_file == &
                         'gate-gate-one.json', 'valid: scene file')
        call assert_int_eq(tl%scenes(1)%scene_ir_version, 1, &
                           'valid: scene ir version pin')
        call assert_int_eq(tl%scenes(1)%end_frame, 48, &
                           'valid: scene end = start + duration')
        call assert_int_eq(tl%scenes(1)%n_bindings, 2, &
                           'valid: 2 bindings')
        call assert_true(kv_lookup(tl%scenes(1)%bindings, &
                         tl%scenes(1)%n_bindings, 'mira') == &
                         'mira_body', 'valid: binding mira')
        call assert_true(kv_lookup(tl%scenes(1)%bindings, &
                         tl%scenes(1)%n_bindings, 'finn') == &
                         'finn_body', 'valid: binding finn')

        call assert_int_eq(tl%n_tracks, 3, 'valid: 3 tracks')
        call assert_true(tl%tracks(1)%kind == 'action', &
                         'valid: track 1 kind')
        call assert_true(tl%tracks(1)%character == 'mira', &
                         'valid: track 1 character')
        call assert_true(tl%tracks(1)%action == 'wave', &
                         'valid: track 1 action symbol')
        call assert_int_eq(tl%tracks(1)%start_frame, 24, &
                           'valid: track 1 start')
        call assert_int_eq(tl%tracks(1)%end_frame, 48, &
                           'valid: track 1 end')
        call assert_true(kv_lookup(tl%tracks(1)%params, &
                         tl%tracks(1)%n_params, 'arm') == 'right', &
                         'valid: track 1 param arm')
        call assert_true(kv_lookup(tl%tracks(1)%params, &
                         tl%tracks(1)%n_params, 'cycles') == '2', &
                         'valid: track 1 param cycles')
        call assert_int_eq(tl%tracks(1)%n_keys, 3, &
                           'valid: action key count')
        call assert_true(tl%tracks(1)%keys(2)%channel == &
                         'arm.r.upper', 'valid: action key channel')
        call assert_true(tl%tracks(1)%keys(2)%has_value_deg, &
                         'valid: action key has value_deg')
        call assert_real_close(tl%tracks(1)%keys(2)%value_deg, &
            -150.0_real64, 1.0e-12_real64, 'valid: action key value')
        call assert_true(tl%tracks(1)%keys(2)%ease == 'smooth', &
                         'valid: action key ease')
        call assert_true(tl%tracks(2)%kind == 'pose_keys', &
                         'valid: track 2 kind')
        call assert_true(tl%tracks(2)%keys(1)%has_pos, &
                         'valid: pose key has pos')
        call assert_real_close(tl%tracks(2)%keys(1)%pos(1), &
            1.5_real64, 1.0e-12_real64, 'valid: pose key pos x')
        call assert_real_close(tl%tracks(2)%keys(1)%rot_deg(2), &
            -20.0_real64, 1.0e-12_real64, 'valid: pose key rot y')
        call assert_true(tl%tracks(2)%keys(1)%has_scale, &
                         'valid: pose key has scale')
        call assert_true(tl%tracks(3)%kind == 'camera', &
                         'valid: track 3 kind')
        call assert_true(tl%tracks(3)%keys(2)%has_fov, &
                         'valid: camera key has fov')
        call assert_real_close(tl%tracks(3)%keys(2)%fov, &
            50.0_real64, 1.0e-12_real64, 'valid: camera key fov')
        call assert_real_close(tl%tracks(3)%keys(2)%target(2), &
            0.5_real64, 1.0e-12_real64, 'valid: camera key target y')
        call assert_true(tl%tracks(3)%has_start .and. &
            tl%tracks(3)%start_frame == 0, &
            'valid: camera span derived from keys (start)')
        call assert_true(tl%tracks(3)%has_end .and. &
            tl%tracks(3)%end_frame == 48, &
            'valid: camera span derived from keys (end)')

        call assert_int_eq(tl%n_dialogue, 1, 'valid: 1 dialogue cue')
        call assert_true(tl%dialogue(1)%speaker == 'mira', &
                         'valid: cue speaker')
        call assert_int_eq(tl%dialogue(1)%start_frame, 12, &
                           'valid: cue start')
        ! Byte-verbatim, UTF-8 (em dash + Bengali) included.
        call assert_true(tl%dialogue(1)%text == &
                         'Finn — হ্যালো, over here!', &
                         'valid: cue text byte-verbatim UTF-8')

        call assert_int_eq(tl%n_markers, 1, 'valid: 1 marker')
        call assert_int_eq(tl%markers(1)%frame, 24, &
                           'valid: marker frame')
        call assert_true(tl%markers(1)%kind == 'beat', &
                         'valid: marker kind')
        call assert_true(tl%markers(1)%name == 'the wave', &
                         'valid: marker name')
        call timeline_free(tl)
    end subroutine check_valid

    ! ---------------------------------------------------------------
    ! The committed fixture file.
    ! ---------------------------------------------------------------
    subroutine check_fixture()
        type(tl_timeline) :: tl
        logical :: ok, ex
        character(len=1024) :: err, cand(4)
        integer :: i
        cand(1) = trim(repo) // '/tests/fixtures/sample.timeline.json'
        cand(2) = 'tests/fixtures/sample.timeline.json'
        cand(3) = '../tests/fixtures/sample.timeline.json'
        cand(4) = '../../tests/fixtures/sample.timeline.json'
        ok = .false.
        do i = 1, 4
            inquire(file=trim(cand(i)), exist=ex)
            if (ex) then
                call read_timeline(trim(cand(i)), tl, ok, err)
                exit
            end if
        end do
        call assert_true(ex, 'fixture: sample.timeline.json located')
        if (.not. ok) write(*, '(A, A)') '  error: ', trim(err)
        call assert_true(ok, 'fixture: read ok')
        if (.not. ok) return
        call assert_true(tl%name == 'gate-scene', 'fixture: name')
        call assert_int_eq(tl%n_characters, 2, 'fixture: characters')
        call assert_true(tl%characters(2)%plugin == 'stickman', &
                         'fixture: plugin id')
        call assert_int_eq(tl%n_tracks, 3, 'fixture: tracks')
        call assert_true(tl%dialogue(1)%text == &
                         'Finn — over here!', 'fixture: cue text')
        call timeline_free(tl)
    end subroutine check_fixture

    ! ---------------------------------------------------------------
    ! Format / version gates (ADR-5 exact-version reader).
    ! ---------------------------------------------------------------
    subroutine check_gates()
        type(tl_timeline) :: tl
        logical :: ok
        character(len=1024) :: err
        character(len=*), parameter :: head = &
            '"name":"x","fps":{"num":24,"den":1},' // &
            '"duration_frames":10'

        call write_doc('noformat.timeline.json', '{' // head // '}')
        call read_timeline(spath('noformat.timeline.json'), tl, &
                           ok, err)
        call assert_false(ok, 'gate: missing format rejected')
        call assert_true(has(err, 'format'), &
                         'gate: missing-format error names format')

        call write_doc('wrongformat.timeline.json', &
            '{"format":"forge3d-scene","ir_version":1,' // head // '}')
        call read_timeline(spath('wrongformat.timeline.json'), tl, &
                           ok, err)
        call assert_false(ok, 'gate: wrong format rejected')
        call assert_true(has(err, 'forge3d-scene'), &
                         'gate: wrong-format error names value found')

        call write_doc('wrongver.timeline.json', &
            '{"format":"forge3d-timeline","ir_version":99,' // &
            head // '}')
        call read_timeline(spath('wrongver.timeline.json'), tl, &
                           ok, err)
        call assert_false(ok, 'gate: ir_version 99 rejected')
        call assert_true(has(err, '99'), &
                         'gate: version error names version found')

        call write_doc('nover.timeline.json', &
            '{"format":"forge3d-timeline",' // head // '}')
        call read_timeline(spath('nover.timeline.json'), tl, ok, err)
        call assert_false(ok, 'gate: missing ir_version rejected')
        call assert_true(has(err, 'ir_version'), &
                         'gate: missing-version error names ir_version')

        call write_doc('nofps.timeline.json', &
            '{"format":"forge3d-timeline","ir_version":1,' // &
            '"name":"x","duration_frames":10}')
        call read_timeline(spath('nofps.timeline.json'), tl, ok, err)
        call assert_false(ok, 'gate: missing fps rejected')
        call assert_true(has(err, 'fps'), &
                         'gate: missing-fps error names fps')

        call read_timeline(spath('does-not-exist.timeline.json'), &
                           tl, ok, err)
        call assert_false(ok, 'gate: missing file rejected')

        call write_doc('broken.timeline.json', '{"format":')
        call read_timeline(spath('broken.timeline.json'), tl, ok, err)
        call assert_false(ok, 'gate: malformed JSON rejected')
        call assert_true(has(err, 'JSON parse failed'), &
                         'gate: malformed error says parse failed')
    end subroutine check_gates

    ! ---------------------------------------------------------------
    ! Unknown track kind: skipped with a diagnostic, never a crash.
    ! Unknown ease: linear + diagnostic (ANIM-PLAN 3.4).
    ! ---------------------------------------------------------------
    subroutine check_skips_and_ease()
        type(tl_timeline) :: tl
        logical :: ok
        character(len=1024) :: err

        call write_doc('skip.timeline.json', &
        '{"format":"forge3d-timeline","ir_version":1,' // &
        '"name":"skip-film","fps":{"num":30,"den":1},' // &
        '"duration_frames":20,"tracks":[' // &
        '{"kind":"teleport","scene":"s1","character":"mira",' // &
        '"start_frame":0,"end_frame":5},' // &
        '{"kind":"camera","scene":"s1","keys":[' // &
        '{"frame":0,"pos":[0,0,5],"target":[0,0,0],"fov":55,' // &
        '"ease":"wobble"},' // &
        '{"frame":20,"pos":[0,0,3],"target":[0,0,0],"fov":55,' // &
        '"ease":"linear"}]}]}')
        call read_timeline(spath('skip.timeline.json'), tl, ok, err)
        if (.not. ok) write(*, '(A, A)') '  error: ', trim(err)
        call assert_true(ok, 'skip: read ok despite unknown kind')
        if (.not. ok) return
        call assert_int_eq(tl%n_tracks, 1, 'skip: 1 known track kept')
        call assert_true(tl%tracks(1)%kind == 'camera', &
                         'skip: kept track is the camera')
        call assert_int_eq(tl%n_skipped_tracks, 1, &
                           'skip: skipped count is 1')
        call assert_true(notes_have(tl, 'teleport'), &
                         'skip: diagnostic names the skipped kind')
        call assert_true(notes_have(tl, 'wobble'), &
                         'ease: diagnostic names the unknown ease')
        call assert_true(tl%tracks(1)%keys(1)%ease == 'linear', &
                         'ease: unknown ease stored as linear')
        call timeline_free(tl)
    end subroutine check_skips_and_ease

    ! ---------------------------------------------------------------
    ! Integer frame sanity.
    ! ---------------------------------------------------------------
    subroutine check_sanity()
        type(tl_timeline) :: tl
        logical :: ok
        character(len=1024) :: err
        character(len=*), parameter :: head = &
            '{"format":"forge3d-timeline","ir_version":1,' // &
            '"name":"bad","fps":{"num":24,"den":1},' // &
            '"duration_frames":48,'

        call write_doc('badspan.timeline.json', head // &
            '"tracks":[{"kind":"action","scene":"s1",' // &
            '"character":"mira","start_frame":30,"end_frame":12,' // &
            '"keys":[]}]}')
        call read_timeline(spath('badspan.timeline.json'), tl, &
                           ok, err)
        call assert_false(ok, 'sanity: track end<start rejected')
        call assert_true(has(err, 'end_frame < start_frame'), &
                         'sanity: end<start error names the span')

        call write_doc('badcue.timeline.json', head // &
            '"dialogue":[{"id":"d1","scene":"s1","start_frame":10,' // &
            '"end_frame":10,"speaker":"mira","text":"hi"}]}')
        call read_timeline(spath('badcue.timeline.json'), tl, ok, err)
        call assert_false(ok, 'sanity: dialogue end<=start rejected')

        call write_doc('badscene.timeline.json', head // &
            '"scenes":[{"id":"s1","scene_file":"x.json",' // &
            '"start_frame":40,"duration_frames":20}]}')
        call read_timeline(spath('badscene.timeline.json'), tl, &
                           ok, err)
        call assert_false(ok, &
            'sanity: scene past timeline duration rejected')
    end subroutine check_sanity

end program test_timeline_ir
