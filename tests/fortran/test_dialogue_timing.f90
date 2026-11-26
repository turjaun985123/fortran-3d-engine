! test_dialogue_timing.f90 -- Wave 3 slice S4: dialogue interval
! lookup in timeline_eval_3d.  Cues are live on the half-open
! interval [start_frame, end_frame), matching the host's
! SubtitleCue::is_live_at and activeDialogue in
! runtime/f3d-timeline.js.
program test_dialogue_timing
    use timeline_eval_3d
    use timeline_ir_3d
    use test_assert
    implicit none

    type(film_state) :: state
    type(tl_dialogue_cue), allocatable :: cues(:)
    integer :: n

    state = film_state()
    allocate(state%tl%dialogue(3))
    state%tl%n_dialogue = 3
    call set_cue(state, 1, 'a', 10, 20)
    call set_cue(state, 2, 'b', 15, 25)
    call set_cue(state, 3, 'c', 30, 40)

    call film_dialogue_at(state, 9, cues, n)
    call assert_int_eq(n, 0, 'no cue before the first start')
    call film_dialogue_at(state, 10, cues, n)
    call assert_int_eq(n, 1, 'cue a live AT its start frame')
    if (n == 1) call assert_true(trim(cues(1)%id) == 'a', &
        'the live cue at 10 is a')
    call film_dialogue_at(state, 19, cues, n)
    call assert_int_eq(n, 2, 'overlapping cues both live at 19')
    call film_dialogue_at(state, 20, cues, n)
    call assert_int_eq(n, 1, 'cue a dead AT its end frame')
    if (n == 1) call assert_true(trim(cues(1)%id) == 'b', &
        'the live cue at 20 is b')
    call film_dialogue_at(state, 25, cues, n)
    call assert_int_eq(n, 0, 'gap between cues: none active')
    call film_dialogue_at(state, 30, cues, n)
    call assert_int_eq(n, 1, 'cue c live at its start')
    call film_dialogue_at(state, 40, cues, n)
    call assert_int_eq(n, 0, 'cue c dead at its end')

    call test_summary()

contains

    subroutine set_cue(state, i, id, st, en)
        type(film_state), intent(inout) :: state
        integer, intent(in) :: i, st, en
        character(len=*), intent(in) :: id
        state%tl%dialogue(i)%id = id
        state%tl%dialogue(i)%scene = 's1'
        state%tl%dialogue(i)%speaker = 'mira'
        state%tl%dialogue(i)%text = 'line'
        state%tl%dialogue(i)%start_frame = st
        state%tl%dialogue(i)%end_frame = en
    end subroutine set_cue

end program test_dialogue_timing
