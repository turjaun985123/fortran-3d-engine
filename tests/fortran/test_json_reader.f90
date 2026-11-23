! test_json_reader.f90 -- tests for the shared JSON parser
! (json_reader_3d, v3.0 Phase 1): every kind, escapes incl. \uXXXX,
! deep nesting, arrays of objects, and error cases.
program test_json_reader
    use, intrinsic :: iso_fortran_env, only: real64
    use json_reader_3d
    use test_assert
    implicit none

    type(json_doc) :: doc
    logical :: ok, found
    character(len=256) :: errmsg
    character(len=:), allocatable :: s
    integer :: child, c2, i, depth, node
    character(len=512) :: deep

    ! ---- a nested document exercising every kind ----
    call json_parse('{' // &
        '"name": "pyramid",' // &
        '"count": 42,' // &
        '"ratio": -12.5e2,' // &
        '"flag": true,' // &
        '"off": false,' // &
        '"nothing": null,' // &
        '"tags": ["a", "b", 3],' // &
        '"nested": {"inner": {"leaf": 2.5}},' // &
        '"objs": [{"id": 1}, {"id": 2}]' // &
        '}', doc, ok, errmsg)
    call assert_true(ok, 'nested document parses')
    call assert_int_eq(5, json_kind(doc, doc%root), 'root kind == obj (5)')
    call assert_int_eq(9, json_obj_count(doc, doc%root), 'root has 9 members')

    call json_obj_get(doc, doc%root, 'name', child, found)
    call assert_true(found, 'obj_get name found')
    call assert_int_eq(3, json_kind(doc, child), 'name kind == str (3)')
    s = json_str(doc, child)
    call assert_true(s == 'pyramid', 'name value == "pyramid" via json_str')
    deallocate(s)
    ! Documented convention: an object child's s component is the KEY.
    call assert_true(doc%nodes(child)%s == 'name', &
        'object child node s holds the key')

    call json_obj_get(doc, doc%root, 'count', child, found)
    call assert_true(found, 'obj_get count found')
    call assert_int_eq(2, json_kind(doc, child), 'count kind == num (2)')
    call assert_real_close(42.0_real64, json_num(doc, child, -1.0_real64), &
        1.0e-12_real64, 'count == 42 via json_num')
    call assert_int_eq(42, json_int(doc, child, -1), 'count == 42 via json_int')

    call json_obj_get(doc, doc%root, 'ratio', child, found)
    call assert_real_close(-1250.0_real64, json_num(doc, child, 0.0_real64), &
        1.0e-9_real64, 'ratio == -12.5e2 == -1250')

    call json_obj_get(doc, doc%root, 'flag', child, found)
    call assert_int_eq(1, json_kind(doc, child), 'flag kind == bool (1)')
    call assert_true(json_bool(doc, child, .false.), 'flag == true')
    call json_obj_get(doc, doc%root, 'off', child, found)
    call assert_false(json_bool(doc, child, .true.), 'off == false')

    call json_obj_get(doc, doc%root, 'nothing', child, found)
    call assert_true(found, 'obj_get nothing found')
    call assert_int_eq(0, json_kind(doc, child), 'nothing kind == null (0)')

    call json_obj_get(doc, doc%root, 'missing', child, found)
    call assert_false(found, 'obj_get missing not found')
    call assert_int_eq(0, child, 'obj_get missing gives child 0')

    ! Defaults on the wrong kind return the caller's default.
    call json_obj_get(doc, doc%root, 'name', child, found)
    call assert_real_close(7.0_real64, json_num(doc, child, 7.0_real64), &
        1.0e-12_real64, 'json_num on a string returns the default')
    call assert_int_eq(-3, json_int(doc, 0, -3), 'json_int on node 0 = default')
    s = json_str(doc, 0)
    call assert_true(len(s) == 0, 'json_str on node 0 is ""')
    deallocate(s)

    ! ---- arrays ----
    call json_obj_get(doc, doc%root, 'tags', child, found)
    call assert_int_eq(4, json_kind(doc, child), 'tags kind == arr (4)')
    call assert_int_eq(3, json_arr_len(doc, child), 'tags length == 3')
    call json_arr_at(doc, child, 1, c2)
    s = json_str(doc, c2)
    call assert_true(s == 'a', 'tags[1] == "a"')
    deallocate(s)
    call json_arr_at(doc, child, 3, c2)
    call assert_int_eq(3, json_int(doc, c2, -1), 'tags[3] == 3')
    call json_arr_at(doc, child, 4, c2)
    call assert_int_eq(0, c2, 'tags[4] out of range gives 0')

    ! ---- nested objects ----
    call json_obj_get(doc, doc%root, 'nested', child, found)
    call json_obj_get(doc, child, 'inner', c2, found)
    call assert_true(found, 'nested.inner found')
    call json_obj_get(doc, c2, 'leaf', child, found)
    call assert_real_close(2.5_real64, json_num(doc, child, 0.0_real64), &
        1.0e-12_real64, 'nested.inner.leaf == 2.5')

    ! ---- array of objects ----
    call json_obj_get(doc, doc%root, 'objs', child, found)
    call assert_int_eq(2, json_arr_len(doc, child), 'objs length == 2')
    call json_arr_at(doc, child, 2, c2)
    call json_obj_get(doc, c2, 'id', child, found)
    call assert_true(found, 'objs[2].id found')
    call assert_int_eq(2, json_int(doc, child, -1), 'objs[2].id == 2')
    call json_free(doc)
    call assert_int_eq(0, doc%n, 'json_free resets the pool')

    ! ---- escapes ----
    call json_parse('{"esc": "a\nb\t\"q\" \\ \/ \u00e9\ud83d\ude00"}', &
        doc, ok, errmsg)
    call assert_true(ok, 'escape document parses')
    call json_obj_get(doc, doc%root, 'esc', child, found)
    s = json_str(doc, child)
    ! Decoded layout: a LF b TAB " q " SP \ SP / SP, then U+00E9 as
    ! 2 UTF-8 bytes (13-14) and U+1F600 as 4 UTF-8 bytes (15-18).
    call assert_int_eq(18, len(s), 'escape string decoded length == 18')
    if (len(s) == 18) then
        call assert_true(s(2:2) == char(10), 'escape \n decoded')
        call assert_true(s(4:4) == char(9), 'escape \t decoded')
        call assert_true(s(5:5) == '"', 'escape \" decoded')
        call assert_true(s(9:9) == '\', 'escape \\ decoded')
        call assert_true(s(11:11) == '/', 'escape \/ decoded')
        call assert_true(iachar(s(13:13)) == 195 .and. &
            iachar(s(14:14)) == 169, 'U+00E9 encoded as UTF-8 C3 A9')
        call assert_true(iachar(s(15:15)) == 240 .and. &
            iachar(s(18:18)) == 128, &
            'surrogate pair U+1F600 encoded as UTF-8 F0 .. 80')
    end if
    deallocate(s)
    call json_free(doc)

    ! ---- scalar roots and int rounding ----
    call json_parse('2.6', doc, ok, errmsg)
    call assert_true(ok, 'bare number parses')
    call assert_int_eq(3, json_int(doc, doc%root, 0), 'json_int rounds 2.6 to 3')
    call json_free(doc)
    call json_parse('  [ ] ', doc, ok, errmsg)
    call assert_true(ok, 'empty array with whitespace parses')
    call assert_int_eq(0, json_arr_len(doc, doc%root), 'empty array length 0')
    call json_free(doc)

    ! ---- deep nesting (>= 64) ----
    deep = ''
    do i = 1, 70
        deep = trim(deep) // '['
    end do
    deep = trim(deep) // '7'
    do i = 1, 70
        deep = trim(deep) // ']'
    end do
    call json_parse(trim(deep), doc, ok, errmsg)
    call assert_true(ok, '70-deep nested arrays parse')
    depth = 0
    node = doc%root
    do while (json_kind(doc, node) == 4)
        depth = depth + 1
        call json_arr_at(doc, node, 1, node)
        if (node == 0) exit
    end do
    call assert_int_eq(70, depth, 'nesting depth == 70')
    call assert_int_eq(7, json_int(doc, node, -1), 'deep leaf == 7')
    call json_free(doc)

    ! ---- error cases: ok=.false. with an offset in the message ----
    call json_parse('{"a": 1,}', doc, ok, errmsg)
    call assert_false(ok, 'trailing comma in object is an error')
    call assert_true(index(errmsg, 'offset') > 0, &
        'error message carries a byte offset')
    call json_parse('[1, 2,]', doc, ok, errmsg)
    call assert_false(ok, 'trailing comma in array is an error')
    call json_parse('{"a": "unterminated}', doc, ok, errmsg)
    call assert_false(ok, 'unterminated string is an error')
    call json_parse('{"a": 1} garbage', doc, ok, errmsg)
    call assert_false(ok, 'trailing garbage is an error')
    call json_parse('', doc, ok, errmsg)
    call assert_false(ok, 'empty input is an error')
    call json_free(doc)

    call test_summary()
end program test_json_reader
