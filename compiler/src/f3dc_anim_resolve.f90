! f3dc_anim_resolve.f90 -- Forge3D action resolver (ANIM Wave 3,
! slice S1; ANIM-PLAN SS3.4 / docs/PLUGINS.md).
!
! Turns one authored character action (plugin id + verb + the
! cue's authored params) into the resolved per-channel key list
! the Timeline IR carries as its normative contract.  Templates
! are SPAN-RELATIVE: keys sit at fractions of [start_frame,
! end_frame]; the cue's ease applies to the primary movement
! end-keys; oscillation keys ease "smooth"; cycle counts derive
! from the span in seconds (span_frames * fps_den / fps_num).
!
! The resolver is called once per action track, in timeline
! order per scene.  It carries a per-character ROOT CURSOR
! (x, y, z + current face.expr) in/out: templates may move it
! through their "cursor" updates, applied only on success.  The
! emitter owns the cursor table (reset per scene to the
! declaration position); this module only reads and updates the
! one character's entry.
!
! Wave 5 (plugin externalization, docs/PLUGINS.md SS3): there
! are NO per-verb templates in this module.  A verb's template
! is DATA in the plugin package, fetched via
! f3dc_plugins:plugin_template, and executed by ONE generic
! interpreter: param_defaults + requires, a step walker over
! "keys" and "osc" steps with "when" guards, the expression
! mini-language (SS3.2), the condition grammar (SS3.3), and
! cursor updates in flat-map form or as a guarded list of
! {set, expr, when} entries (coordinator ruling, Wave 5).  The
! interpreter contains no verb name, channel name or template
! constant.  A verb resolves only when the character's plugin
! publishes a template for it; plugins that publish none (and
! the core verbs, which are not plugin templates at all) report
! resolved=.false. and the emitter keeps its Wave-2 output for
! the track.
module f3dc_anim_resolve
  use, intrinsic :: iso_fortran_env, only: int64, real64
  use f3dc_dyn, only: dyn, dyn_null, dyn_int, dyn_real, dyn_str, &
       dyn_list, dyn_dict, dyn_copy, dyn_assign, dyn_list_push, &
       dyn_list_len, &
       dyn_list_at, dyn_list_set_at, dyn_dict_get, dyn_dict_set, &
       dyn_dict_has, dyn_dict_remove, dyn_dict_len, &
       dyn_dict_key_at, dyn_dict_value_at, DYN_K_NULL, &
       DYN_K_BOOL, DYN_K_INT, DYN_K_REAL, &
       DYN_K_STR, DYN_K_LIST, DYN_K_DICT
  use f3dc_plugins, only: plugin_template, &
       plugin_expression_code, plugin_rig_channel_form
  use f3dc_str, only: to_lower
  implicit none
  private
  public :: anim_resolve

  real(real64), parameter :: PI = 3.141592653589793_real64

  ! Work state for one resolution (the compiler is
  ! single-threaded; the emitter calls us strictly sequentially).
  character(:), allocatable :: w_plugin, w_ease
  type(dyn) :: w_params, w_others, w_keys
  integer(int64) :: w_sf, w_ef
  real(real64) :: w_decl(3), w_span_sec
  integer :: w_ord
  ! The character's cursor as expressions see it: initialised
  ! from the entry cursor, mutated only by the template's
  ! cursor updates (which run after every step, in order, so
  ! key expressions always read the entry cursor -- exactly
  ! what the pre-externalization templates did).
  real(real64) :: w_cur(3), w_exprv
  ! The fraction of the key currently being built (the "f" ref
  ! of the expression language); 0 outside key construction.
  real(real64) :: w_frac

  ! Expression-evaluator state (one evaluation at a time).
  character(:), allocatable :: e_s
  integer :: e_pos
  logical :: e_ok

contains

  ! ---------------------------------------------------------------
  ! Entry point.  CURSOR (in/out) is the character's root
  ! position; EXPR (in/out) its current face.expr code.  DECL is
  ! the declaration position.  OTHERS is a dyn list of
  ! {name, pos} dicts: every character declared in the scene,
  ! for target-by-name lookups.  On success KEYS is the sorted,
  ! de-duplicated key list and RESOLVED is true; on failure KEYS
  ! is empty and RESOLVED is false (cursor/expr untouched).
  ! ---------------------------------------------------------------
  subroutine anim_resolve(plugin_id, verb, params, cue_ease, &
                          sf, ef, fps_num, fps_den, decl, &
                          cursor, expr, others, keys, resolved)
    character(*), intent(in) :: plugin_id, verb, cue_ease
    type(dyn), intent(in) :: params, others
    integer(int64), intent(in) :: sf, ef, fps_num, fps_den
    real(real64), intent(in) :: decl(3)
    real(real64), intent(inout) :: cursor(3), expr
    type(dyn), intent(out) :: keys
    logical, intent(out) :: resolved
    type(dyn) :: tpl
    logical :: found, ok
    keys = dyn_list()
    resolved = .false.
    call plugin_template(plugin_id, verb, tpl, found)
    if (.not. found) return
    if (ef <= sf) return
    w_plugin = plugin_id
    w_ease = cue_ease
    if (len(w_ease) == 0) w_ease = "linear"
    call dyn_assign(w_params, params)
    call dyn_assign(w_others, others)
    w_sf = sf
    w_ef = ef
    w_decl = decl
    w_span_sec = real(ef - sf, real64) * real(fps_den, real64) &
                 / real(fps_num, real64)
    w_cur = cursor
    w_exprv = expr
    w_frac = 0.0_real64
    w_keys = dyn_list()
    w_ord = 0
    call apply_defaults(tpl, ok)
    if (.not. ok) return
    call check_requires(tpl, ok)
    if (.not. ok) return
    call run_steps(tpl, ok)
    if (.not. ok) return
    if (tpl_fail_if_empty(tpl) .and. dyn_list_len(w_keys) == 0) &
      return
    call apply_cursor(tpl)
    cursor = w_cur
    expr = w_exprv
    resolved = .true.
    call finish_keys(keys)
  end subroutine anim_resolve

  ! ---------------------------------------------------------------
  ! Template driver: param_defaults, requires, fail_if_empty,
  ! cursor updates (docs/PLUGINS.md SS3.1 + the Wave-5 guarded
  ! cursor-list extension).
  ! ---------------------------------------------------------------

  !> Apply the template's param_defaults to the effective
  !! params, in declaration order: a default fills only a param
  !! the cue did not supply.  A default is a JSON literal
  !! (copied), {"expr": "..."} evaluated numerically -- or, when
  !! the expr is a bare "param.NAME" reference, an alias: the
  !! referenced param's value is copied verbatim, whatever its
  !! kind (this is how a string param defaults from another
  !! string param).  A numeric default whose evaluation fails
  !! fails the template.
  subroutine apply_defaults(tpl, ok)
    type(dyn), intent(in) :: tpl
    logical, intent(out) :: ok
    type(dyn) :: d, val, ev, pv
    character(:), allocatable :: key, es, pname
    integer :: m
    real(real64) :: x
    logical :: eok
    ok = .true.
    d = dyn_dict_get(tpl, "param_defaults")
    if (d%kind /= DYN_K_DICT) return
    do m = 1, dyn_dict_len(d)
      key = dyn_dict_key_at(d, m)
      if (dyn_dict_has(w_params, key)) cycle
      val = dyn_dict_value_at(d, m)
      if (val%kind == DYN_K_DICT .and. &
          dyn_dict_has(val, "expr")) then
        ev = dyn_dict_get(val, "expr")
        if (ev%kind /= DYN_K_STR) then
          ok = .false.
          return
        end if
        es = ev%s
        if (bare_param_ref(es, pname)) then
          pv = dyn_dict_get(w_params, pname)
          if (pv%kind /= DYN_K_NULL) &
            call dyn_dict_set(w_params, key, dyn_copy(pv))
        else
          w_frac = 0.0_real64
          call eval_expr(es, x, eok)
          if (.not. eok) then
            ok = .false.
            return
          end if
          call dyn_dict_set(w_params, key, dyn_real(x))
        end if
      else
        call dyn_dict_set(w_params, key, dyn_copy(val))
      end if
    end do
  end subroutine apply_defaults

  !> True when S, ignoring surrounding blanks, is exactly
  !! "param.NAME"; PNAME receives NAME.
  logical function bare_param_ref(s, pname) result(is_ref)
    character(*), intent(in) :: s
    character(:), allocatable, intent(out) :: pname
    integer :: a, b, i
    character(1) :: c
    is_ref = .false.
    pname = ""
    a = 1
    do while (a <= len(s) .and. s(a:a) == " ")
      a = a + 1
    end do
    b = len(s)
    do while (b >= a .and. s(b:b) == " ")
      b = b - 1
    end do
    if (b - a + 1 <= 6) return
    if (s(a:a + 5) /= "param.") return
    do i = a + 6, b
      c = s(i:i)
      if (.not. ((c >= "a" .and. c <= "z") .or. &
                 (c >= "A" .and. c <= "Z") .or. &
                 (c >= "0" .and. c <= "9") .or. c == "_")) return
    end do
    pname = s(a + 6:b)
    is_ref = .true.
  end function bare_param_ref

  !> Every condition in the template's "requires" list must
  !! hold or the template is unresolved.
  subroutine check_requires(tpl, ok)
    type(dyn), intent(in) :: tpl
    logical, intent(out) :: ok
    type(dyn) :: r
    integer :: i
    ok = .true.
    r = dyn_dict_get(tpl, "requires")
    if (r%kind /= DYN_K_LIST) return
    do i = 1, dyn_list_len(r)
      if (.not. eval_cond(dyn_list_at(r, i))) then
        ok = .false.
        return
      end if
    end do
  end subroutine check_requires

  logical function tpl_fail_if_empty(tpl) result(f)
    type(dyn), intent(in) :: tpl
    type(dyn) :: v
    v = dyn_dict_get(tpl, "fail_if_empty")
    f = v%kind == DYN_K_BOOL .and. v%b
  end function tpl_fail_if_empty

  !> Apply the template's cursor updates (success only).  Two
  !! forms: the flat map {"x": v, "y": v, "z": v, "expr": v}
  !! and the guarded list [{"set": "cursor.x", "expr": e,
  !! "when": cond}, ...] whose entries apply in order, each
  !! only when its guard holds (entries without "when" apply
  !! unconditionally).  A value is a number or an expression
  !! string; an update whose expression fails to evaluate is
  !! skipped, not fatal (docs/PLUGINS.md SS3.4: the yaw branches
  !! of a facing template never touch the expression cursor).
  subroutine apply_cursor(tpl)
    type(dyn), intent(in) :: tpl
    type(dyn) :: c, e, sv, val
    character(:), allocatable :: set_name
    integer :: i
    c = dyn_dict_get(tpl, "cursor")
    select case (c%kind)
    case (DYN_K_DICT)
      call cursor_one("x", dyn_dict_get(c, "x"))
      call cursor_one("y", dyn_dict_get(c, "y"))
      call cursor_one("z", dyn_dict_get(c, "z"))
      call cursor_one("expr", dyn_dict_get(c, "expr"))
    case (DYN_K_LIST)
      do i = 1, dyn_list_len(c)
        e = dyn_list_at(c, i)
        if (e%kind /= DYN_K_DICT) cycle
        if (dyn_dict_has(e, "when")) then
          if (.not. eval_cond(dyn_dict_get(e, "when"))) cycle
        end if
        sv = dyn_dict_get(e, "set")
        if (sv%kind /= DYN_K_STR) cycle
        set_name = sv%s
        val = dyn_dict_get(e, "expr")
        if (val%kind == DYN_K_NULL) val = dyn_dict_get(e, "value")
        select case (set_name)
        case ("cursor.x", "x")
          call cursor_one("x", val)
        case ("cursor.y", "y")
          call cursor_one("y", val)
        case ("cursor.z", "z")
          call cursor_one("z", val)
        case ("expr", "cursor.expr")
          call cursor_one("expr", val)
        end select
      end do
    end select
  end subroutine apply_cursor

  subroutine cursor_one(name, val)
    character(*), intent(in) :: name
    type(dyn), intent(in) :: val
    real(real64) :: x
    logical :: eok
    select case (val%kind)
    case (DYN_K_INT)
      x = real(val%i, real64)
    case (DYN_K_REAL)
      x = val%r
    case (DYN_K_STR)
      w_frac = 0.0_real64
      call eval_expr(val%s, x, eok)
      if (.not. eok) return
    case default
      return
    end select
    select case (name)
    case ("x")
      w_cur(1) = x
    case ("y")
      w_cur(2) = x
    case ("z")
      w_cur(3) = x
    case ("expr")
      w_exprv = x
    end select
  end subroutine cursor_one

  ! ---------------------------------------------------------------
  ! Step walker: "keys" steps and "osc" steps, each optionally
  ! guarded by a "when" condition.
  ! ---------------------------------------------------------------
  subroutine run_steps(tpl, ok)
    type(dyn), intent(in) :: tpl
    logical, intent(out) :: ok
    type(dyn) :: steps, st, kl
    integer :: i, j
    ok = .true.
    steps = dyn_dict_get(tpl, "steps")
    if (steps%kind /= DYN_K_LIST) return
    do i = 1, dyn_list_len(steps)
      st = dyn_list_at(steps, i)
      if (st%kind /= DYN_K_DICT) cycle
      if (dyn_dict_has(st, "when")) then
        if (.not. eval_cond(dyn_dict_get(st, "when"))) cycle
      end if
      if (dyn_dict_has(st, "keys")) then
        kl = dyn_dict_get(st, "keys")
        if (kl%kind /= DYN_K_LIST) cycle
        do j = 1, dyn_list_len(kl)
          call emit_key(dyn_list_at(kl, j), ok)
          if (.not. ok) return
        end do
      else if (dyn_dict_has(st, "osc")) then
        call run_osc(dyn_dict_get(st, "osc"), ok)
        if (.not. ok) return
      end if
    end do
  end subroutine run_steps

  !> One explicit key: {"channel", "at", "value", "ease"}.  AT
  !! is a fraction of the span or "start"/"end"; VALUE a number
  !! or an expression string (evaluated with f = the key's own
  !! fraction); EASE "cue" selects the cue's ease.
  subroutine emit_key(kd, ok)
    type(dyn), intent(in) :: kd
    logical, intent(out) :: ok
    type(dyn) :: ch, at, val, es
    character(:), allocatable :: channel, ease_s
    integer(int64) :: frame
    real(real64) :: frac, x
    logical :: eok
    ok = .false.
    if (kd%kind /= DYN_K_DICT) return
    ch = dyn_dict_get(kd, "channel")
    if (ch%kind /= DYN_K_STR) return
    channel = ch%s
    at = dyn_dict_get(kd, "at")
    select case (at%kind)
    case (DYN_K_INT)
      frac = real(at%i, real64)
      frame = frame_at(frac)
    case (DYN_K_REAL)
      frac = at%r
      frame = frame_at(frac)
    case (DYN_K_STR)
      if (at%s == "end") then
        frac = 1.0_real64
        frame = w_ef
      else
        frac = 0.0_real64
        frame = w_sf
      end if
    case default
      frac = 0.0_real64
      frame = w_sf
    end select
    val = dyn_dict_get(kd, "value")
    select case (val%kind)
    case (DYN_K_INT)
      x = real(val%i, real64)
    case (DYN_K_REAL)
      x = val%r
    case (DYN_K_STR)
      w_frac = frac
      call eval_expr(val%s, x, eok)
      if (.not. eok) return
    case default
      return
    end select
    es = dyn_dict_get(kd, "ease")
    if (es%kind == DYN_K_STR .and. es%s /= "cue") then
      ease_s = es%s
    else
      ease_s = w_ease
    end if
    call add_key(frame, channel, x, ease_s)
    ok = .true.
  end subroutine emit_key

  !> One sampled generator step:
  !! {"channel", "waveform", "base", "amp", "cycles",
  !!  "phase_deg", "from", "to", "ease"}.  The grid is
  !! steps = max(4 * cycles, 1) keys at grid parameter
  !! t = i/steps; the key sits at fraction from + (to - from) *
  !! i/steps while the waveform is phased by t (the step
  !! index), exactly as the pre-externalization samplers did.
  !! Waveforms: sin = base + amp * sin(2pi*cycles*t + phase);
  !! abs_sin likewise with |sin|; bob = base + amp *
  !! (0.5 - 0.5 * cos(4pi*cycles*t)).  Cycles is {"hz": h}
  !! (max(1, nint(span_sec * h))), {"expr": "..."} or a number,
  !! always clamped to >= 1.  Base/amp are numbers or
  !! expression strings evaluated once per step.
  subroutine run_osc(od, ok)
    type(dyn), intent(in) :: od
    logical, intent(out) :: ok
    type(dyn) :: ch, wv, cy, es
    character(:), allocatable :: channel, wave, ease_s
    integer :: cyc, i, steps
    real(real64) :: base, amp, phase, frm, to, t, fk, ph, x
    logical :: eok
    ok = .false.
    if (od%kind /= DYN_K_DICT) return
    ch = dyn_dict_get(od, "channel")
    if (ch%kind /= DYN_K_STR) return
    channel = ch%s
    wv = dyn_dict_get(od, "waveform")
    if (wv%kind == DYN_K_STR) then
      wave = wv%s
    else
      wave = "sin"
    end if
    if (wave /= "sin" .and. wave /= "abs_sin" .and. &
        wave /= "bob") return
    cy = dyn_dict_get(od, "cycles")
    cyc = 1
    select case (cy%kind)
    case (DYN_K_DICT)
      if (dyn_dict_has(cy, "hz")) then
        call dyn_num(dyn_dict_get(cy, "hz"), x, eok)
        if (.not. eok) return
        cyc = cycles_at(x)
      else if (dyn_dict_has(cy, "expr")) then
        block
          type(dyn) :: ev
          ev = dyn_dict_get(cy, "expr")
          if (ev%kind /= DYN_K_STR) return
          w_frac = 0.0_real64
          call eval_expr(ev%s, x, eok)
          if (.not. eok) return
          cyc = max(1, nint(x))
        end block
      else
        return
      end if
    case (DYN_K_INT)
      cyc = max(1, int(cy%i))
    case (DYN_K_REAL)
      cyc = max(1, nint(cy%r))
    case (DYN_K_NULL)
      cyc = 1
    case default
      return
    end select
    call num_or_expr(dyn_dict_get(od, "base"), 0.0_real64, &
                     base, eok)
    if (.not. eok) return
    call num_or_expr(dyn_dict_get(od, "amp"), 0.0_real64, &
                     amp, eok)
    if (.not. eok) return
    call num_or_expr(dyn_dict_get(od, "phase_deg"), &
                     0.0_real64, x, eok)
    if (.not. eok) return
    phase = x / 180.0_real64 * PI
    call num_or_expr(dyn_dict_get(od, "from"), 0.0_real64, &
                     frm, eok)
    if (.not. eok) return
    call num_or_expr(dyn_dict_get(od, "to"), 1.0_real64, &
                     to, eok)
    if (.not. eok) return
    es = dyn_dict_get(od, "ease")
    if (es%kind == DYN_K_STR .and. es%s /= "cue") then
      ease_s = es%s
    else if (es%kind == DYN_K_STR) then
      ease_s = w_ease
    else
      ease_s = "smooth"
    end if
    steps = max(4 * cyc, 1)
    do i = 0, steps
      t = real(i, real64) / real(steps, real64)
      fk = frm + (to - frm) * real(i, real64) &
           / real(steps, real64)
      select case (wave)
      case ("sin")
        x = base + amp * sin(2.0_real64 * PI &
            * real(cyc, real64) * t + phase)
      case ("abs_sin")
        x = base + amp * abs(sin(2.0_real64 * PI &
            * real(cyc, real64) * t + phase))
      case ("bob")
        ph = 2.0_real64 * PI * real(cyc, real64) * t
        x = base + amp * (0.5_real64 - 0.5_real64 &
            * cos(2.0_real64 * ph))
      end select
      call add_key_f(fk, channel, x, ease_s)
    end do
    ok = .true.
  end subroutine run_osc

  !> A number-valued template field: a JSON number, or an
  !! expression string evaluated once (f = 0); DEFAULT when the
  !! field is absent.
  subroutine num_or_expr(v, default, x, ok)
    type(dyn), intent(in) :: v
    real(real64), intent(in) :: default
    real(real64), intent(out) :: x
    logical, intent(out) :: ok
    ok = .true.
    select case (v%kind)
    case (DYN_K_INT)
      x = real(v%i, real64)
    case (DYN_K_REAL)
      x = v%r
    case (DYN_K_STR)
      w_frac = 0.0_real64
      call eval_expr(v%s, x, ok)
    case default
      x = default
    end select
  end subroutine num_or_expr

  subroutine dyn_num(v, x, ok)
    type(dyn), intent(in) :: v
    real(real64), intent(out) :: x
    logical, intent(out) :: ok
    ok = .true.
    x = 0.0_real64
    select case (v%kind)
    case (DYN_K_INT)
      x = real(v%i, real64)
    case (DYN_K_REAL)
      x = v%r
    case default
      ok = .false.
    end select
  end subroutine dyn_num

  integer function cycles_at(hz) result(cyc)
    real(real64), intent(in) :: hz
    cyc = max(1, nint(w_span_sec * hz))
  end function cycles_at

  ! ---------------------------------------------------------------
  ! Condition grammar (docs/PLUGINS.md SS3.3): a condition is a
  ! single-key object.  A condition whose expressions fail to
  ! evaluate is false.
  ! ---------------------------------------------------------------
  recursive logical function eval_cond(c) result(tf)
    type(dyn), intent(in) :: c
    character(:), allocatable :: key, nm, want
    type(dyn) :: v, item, lst
    real(real64) :: pos(3), a, b
    character(:), allocatable :: nm_out
    logical :: found, eok
    integer :: i
    tf = .false.
    if (c%kind /= DYN_K_DICT) return
    if (dyn_dict_len(c) < 1) return
    key = dyn_dict_key_at(c, 1)
    v = dyn_dict_value_at(c, 1)
    select case (key)
    case ("param_eq")
      if (.not. pair_strs(v, nm, want)) return
      tf = pstr(nm, "") == to_lower(want)
    case ("param_in")
      if (v%kind /= DYN_K_LIST .or. dyn_list_len(v) < 2) return
      if (.not. dyn_str_of(dyn_list_at(v, 1), nm)) return
      lst = dyn_list_at(v, 2)
      if (lst%kind /= DYN_K_LIST) return
      do i = 1, dyn_list_len(lst)
        if (.not. dyn_str_of(dyn_list_at(lst, i), want)) cycle
        if (pstr(nm, "") == to_lower(want)) then
          tf = .true.
          return
        end if
      end do
    case ("param_present")
      if (.not. dyn_str_of(v, nm)) return
      tf = dyn_dict_has(w_params, nm)
    case ("dest_found")
      if (.not. dyn_str_of(v, nm)) return
      call dest_pos(nm, pos, found, nm_out)
      tf = found
    case ("name_is")
      if (.not. pair_strs(v, nm, want)) return
      call dest_pos(nm, pos, found, nm_out)
      tf = nm_out == want
    case ("lt", "ge", "eq")
      if (v%kind /= DYN_K_LIST .or. dyn_list_len(v) < 2) return
      if (.not. dyn_str_of(dyn_list_at(v, 1), nm)) return
      if (.not. dyn_str_of(dyn_list_at(v, 2), want)) return
      w_frac = 0.0_real64
      call eval_expr(nm, a, eok)
      if (.not. eok) return
      call eval_expr(want, b, eok)
      if (.not. eok) return
      select case (key)
      case ("lt")
        tf = a < b
      case ("ge")
        tf = a >= b
      case ("eq")
        tf = a == b
      end select
    case ("all")
      if (v%kind /= DYN_K_LIST) return
      tf = .true.
      do i = 1, dyn_list_len(v)
        if (.not. eval_cond(dyn_list_at(v, i))) then
          tf = .false.
          return
        end if
      end do
    case ("any")
      if (v%kind /= DYN_K_LIST) return
      do i = 1, dyn_list_len(v)
        if (eval_cond(dyn_list_at(v, i))) then
          tf = .true.
          return
        end if
      end do
    case ("not")
      tf = .not. eval_cond(v)
    case default
      tf = .false.
    end select
  end function eval_cond

  logical function dyn_str_of(v, s) result(ok)
    type(dyn), intent(in) :: v
    character(:), allocatable, intent(out) :: s
    ok = v%kind == DYN_K_STR
    if (ok) then
      s = v%s
    else
      s = ""
    end if
  end function dyn_str_of

  logical function pair_strs(v, a, b) result(ok)
    type(dyn), intent(in) :: v
    character(:), allocatable, intent(out) :: a, b
    ok = .false.
    a = ""
    b = ""
    if (v%kind /= DYN_K_LIST .or. dyn_list_len(v) < 2) return
    if (.not. dyn_str_of(dyn_list_at(v, 1), a)) return
    if (.not. dyn_str_of(dyn_list_at(v, 2), b)) return
    ok = .true.
  end function pair_strs

  ! ---------------------------------------------------------------
  ! Expression mini-language (docs/PLUGINS.md SS3.2):
  !   expr   := term (("+"|"-") term)*
  !   term   := factor (("*"|"/") factor)*
  !   factor := "-" factor | "(" expr ")" | number | ref | call
  ! Refs: cursor.x/y/z, decl.x/y/z, span_sec, f, pi,
  ! param.NAME (numeric), dest(NAME).x/y/z.  Calls:
  ! atan2_deg, clamp, min, max, nint, expr_code(param.NAME).
  ! Evaluation failure is a value (E_OK false), never a trap:
  ! a string param in a numeric position, a missing param, an
  ! unknown expression name or a missing destination all fail,
  ! and a failed evaluation fails the whole template (or skips
  ! a cursor update).
  ! ---------------------------------------------------------------
  subroutine eval_expr(s, val, ok)
    character(*), intent(in) :: s
    real(real64), intent(out) :: val
    logical, intent(out) :: ok
    e_s = s
    e_pos = 1
    e_ok = .true.
    val = p_expr()
    call e_skip()
    if (e_pos <= len(e_s)) e_ok = .false.
    ok = e_ok
    if (.not. ok) val = 0.0_real64
  end subroutine eval_expr

  subroutine e_skip()
    do while (e_pos <= len(e_s))
      if (e_s(e_pos:e_pos) /= " ") exit
      e_pos = e_pos + 1
    end do
  end subroutine e_skip

  character(1) function e_peek() result(c)
    if (e_pos <= len(e_s)) then
      c = e_s(e_pos:e_pos)
    else
      c = char(0)
    end if
  end function e_peek

  logical function e_is_word(c) result(w)
    character(1), intent(in) :: c
    w = (c >= "a" .and. c <= "z") .or. &
        (c >= "A" .and. c <= "Z") .or. &
        (c >= "0" .and. c <= "9") .or. c == "_" .or. c == "."
  end function e_is_word

  recursive function p_expr() result(v)
    real(real64) :: v, t
    character(1) :: c
    v = p_term()
    do while (e_ok)
      call e_skip()
      c = e_peek()
      if (c == "+") then
        e_pos = e_pos + 1
        t = p_term()
        v = v + t
      else if (c == "-") then
        e_pos = e_pos + 1
        t = p_term()
        v = v - t
      else
        exit
      end if
    end do
  end function p_expr

  recursive function p_term() result(v)
    real(real64) :: v, t
    character(1) :: c
    v = p_factor()
    do while (e_ok)
      call e_skip()
      c = e_peek()
      if (c == "*") then
        e_pos = e_pos + 1
        t = p_factor()
        v = v * t
      else if (c == "/") then
        e_pos = e_pos + 1
        t = p_factor()
        v = v / t
      else
        exit
      end if
    end do
  end function p_term

  recursive function p_factor() result(v)
    real(real64) :: v
    character(1) :: c
    v = 0.0_real64
    if (.not. e_ok) return
    call e_skip()
    c = e_peek()
    if (c == "-") then
      e_pos = e_pos + 1
      v = -p_factor()
    else if (c == "+") then
      e_pos = e_pos + 1
      v = p_factor()
    else if (c == "(") then
      e_pos = e_pos + 1
      v = p_expr()
      call e_skip()
      if (e_peek() == ")") then
        e_pos = e_pos + 1
      else
        e_ok = .false.
      end if
    else if ((c >= "0" .and. c <= "9") .or. c == ".") then
      v = p_number()
    else if ((c >= "a" .and. c <= "z") .or. &
             (c >= "A" .and. c <= "Z") .or. c == "_") then
      v = p_ref()
    else
      e_ok = .false.
    end if
  end function p_factor

  function p_number() result(v)
    real(real64) :: v
    integer :: a, ios
    character(1) :: c
    v = 0.0_real64
    a = e_pos
    do while (e_pos <= len(e_s))
      c = e_s(e_pos:e_pos)
      if (c < "0" .or. c > "9") exit
      e_pos = e_pos + 1
    end do
    if (e_peek() == ".") then
      e_pos = e_pos + 1
      do while (e_pos <= len(e_s))
        c = e_s(e_pos:e_pos)
        if (c < "0" .or. c > "9") exit
        e_pos = e_pos + 1
      end do
    end if
    c = e_peek()
    if (c == "e" .or. c == "E") then
      e_pos = e_pos + 1
      c = e_peek()
      if (c == "+" .or. c == "-") e_pos = e_pos + 1
      do while (e_pos <= len(e_s))
        c = e_s(e_pos:e_pos)
        if (c < "0" .or. c > "9") exit
        e_pos = e_pos + 1
      end do
    end if
    if (e_pos == a) then
      e_ok = .false.
      return
    end if
    read (e_s(a:e_pos - 1), *, iostat=ios) v
    if (ios /= 0) e_ok = .false.
  end function p_number

  !> Scan a word ([A-Za-z0-9_.]*) at the cursor.
  function p_word() result(w)
    character(:), allocatable :: w
    integer :: a
    a = e_pos
    do while (e_pos <= len(e_s))
      if (.not. e_is_word(e_s(e_pos:e_pos))) exit
      e_pos = e_pos + 1
    end do
    if (e_pos > a) then
      w = e_s(a:e_pos - 1)
    else
      w = ""
    end if
  end function p_word

  recursive function p_ref() result(v)
    real(real64) :: v
    character(:), allocatable :: w, nm, comp
    type(dyn) :: pv
    real(real64) :: pos(3)
    logical :: found
    v = 0.0_real64
    w = p_word()
    if (w == "dest") then
      ! dest(NAME).x/y/z -- the existing dest_pos lookup.
      call e_skip()
      if (e_peek() /= "(") then
        e_ok = .false.
        return
      end if
      e_pos = e_pos + 1
      call e_skip()
      nm = p_word()
      call e_skip()
      if (e_peek() /= ")") then
        e_ok = .false.
        return
      end if
      e_pos = e_pos + 1
      if (e_peek() /= ".") then
        e_ok = .false.
        return
      end if
      e_pos = e_pos + 1
      comp = p_word()
      block
        character(:), allocatable :: nm_out
        call dest_pos(nm, pos, found, nm_out)
      end block
      if (.not. found) then
        e_ok = .false.
        return
      end if
      select case (comp)
      case ("x")
        v = pos(1)
      case ("y")
        v = pos(2)
      case ("z")
        v = pos(3)
      case default
        e_ok = .false.
      end select
    else if (w == "expr_code") then
      ! expr_code(param.NAME): the param's string value is an
      ! expression name in the plugin's expression_codes map.
      call e_skip()
      if (e_peek() /= "(") then
        e_ok = .false.
        return
      end if
      e_pos = e_pos + 1
      call e_skip()
      nm = p_word()
      call e_skip()
      if (e_peek() /= ")") then
        e_ok = .false.
        return
      end if
      e_pos = e_pos + 1
      if (len(nm) <= 6 .or. nm(1:6) /= "param.") then
        e_ok = .false.
        return
      end if
      pv = dyn_dict_get(w_params, nm(7:))
      if (pv%kind /= DYN_K_STR) then
        e_ok = .false.
        return
      end if
      block
        integer :: icode
        call plugin_expression_code(w_plugin, to_lower(pv%s), &
                                    icode, found)
        if (.not. found) then
          e_ok = .false.
          return
        end if
        v = real(icode, real64)
      end block
    else if (w == "atan2_deg" .or. w == "clamp" .or. &
             w == "min" .or. w == "max" .or. w == "nint") then
      v = p_call(w)
    else if (w == "cursor.x") then
      v = w_cur(1)
    else if (w == "cursor.y") then
      v = w_cur(2)
    else if (w == "cursor.z") then
      v = w_cur(3)
    else if (w == "decl.x") then
      v = w_decl(1)
    else if (w == "decl.y") then
      v = w_decl(2)
    else if (w == "decl.z") then
      v = w_decl(3)
    else if (w == "span_sec") then
      v = w_span_sec
    else if (w == "f") then
      v = w_frac
    else if (w == "pi") then
      v = PI
    else if (len(w) > 6 .and. w(1:6) == "param.") then
      pv = dyn_dict_get(w_params, w(7:))
      select case (pv%kind)
      case (DYN_K_INT)
        v = real(pv%i, real64)
      case (DYN_K_REAL)
        v = pv%r
      case default
        e_ok = .false.
      end select
    else
      e_ok = .false.
    end if
  end function p_ref

  recursive function p_call(name) result(v)
    character(*), intent(in) :: name
    real(real64) :: v, args(3)
    integer :: n, i
    v = 0.0_real64
    call e_skip()
    if (e_peek() /= "(") then
      e_ok = .false.
      return
    end if
    e_pos = e_pos + 1
    n = 0
    do i = 1, 3
      call e_skip()
      if (e_peek() == ")") exit
      if (i > 1) then
        if (e_peek() /= ",") then
          e_ok = .false.
          return
        end if
        e_pos = e_pos + 1
      end if
      n = n + 1
      args(n) = p_expr()
      if (.not. e_ok) return
      call e_skip()
      if (e_peek() == ")") exit
    end do
    if (e_peek() /= ")") then
      e_ok = .false.
      return
    end if
    e_pos = e_pos + 1
    select case (name)
    case ("atan2_deg")
      if (n /= 2) then
        e_ok = .false.
        return
      end if
      v = atan2(args(1), args(2)) * 180.0_real64 / PI
    case ("clamp")
      if (n /= 3) then
        e_ok = .false.
        return
      end if
      v = max(args(2), min(args(3), args(1)))
    case ("min")
      if (n /= 2) then
        e_ok = .false.
        return
      end if
      v = min(args(1), args(2))
    case ("max")
      if (n /= 2) then
        e_ok = .false.
        return
      end if
      v = max(args(1), args(2))
    case ("nint")
      if (n /= 1) then
        e_ok = .false.
        return
      end if
      v = real(nint(args(1), int64), real64)
    end select
  end function p_call

  ! ---------------------------------------------------------------
  ! Key construction helpers
  ! ---------------------------------------------------------------

  !> Snap a value that is within 1e-9 of an integer (or of zero)
  !! onto it: keeps sin/cos quarter-point values byte-clean.
  pure real(real64) function snap(v) result(out)
    real(real64), intent(in) :: v
    out = v
    if (abs(v - real(nint(v, int64), real64)) < 1.0e-9_real64) &
      out = real(nint(v, int64), real64)
    if (out == 0.0_real64) out = 0.0_real64  ! normalise -0.0
  end function snap

  integer(int64) function frame_at(frac) result(fr)
    real(real64), intent(in) :: frac
    fr = w_sf + nint(frac * real(w_ef - w_sf, real64), int64)
  end function frame_at

  !> Append one key.  The value key is "value_deg" when the
  !! plugin publishes CHANNEL as a degree channel, else "value".
  subroutine add_key(frame, channel, value, ease)
    integer(int64), intent(in) :: frame
    character(*), intent(in) :: channel, ease
    real(real64), intent(in) :: value
    type(dyn) :: k
    character(:), allocatable :: form
    logical :: found
    k = dyn_dict()
    call dyn_dict_set(k, "frame", dyn_int(frame))
    call dyn_dict_set(k, "channel", dyn_str(channel))
    call plugin_rig_channel_form(w_plugin, channel, form, found)
    if (found .and. form == "deg") then
      call dyn_dict_set(k, "value_deg", dyn_real(snap(value)))
    else
      call dyn_dict_set(k, "value", dyn_real(snap(value)))
    end if
    call dyn_dict_set(k, "ease", dyn_str(ease))
    w_ord = w_ord + 1
    call dyn_dict_set(k, "_ord", dyn_int(int(w_ord, int64)))
    call dyn_list_push(w_keys, k)
  end subroutine add_key

  subroutine add_key_f(frac, channel, value, ease)
    real(real64), intent(in) :: frac, value
    character(*), intent(in) :: channel, ease
    call add_key(frame_at(frac), channel, value, ease)
  end subroutine add_key_f

  ! ---------------------------------------------------------------
  ! Param access helpers
  ! ---------------------------------------------------------------

  function pstr(key, default) result(out)
    character(*), intent(in) :: key, default
    character(:), allocatable :: out
    type(dyn) :: v
    v = dyn_dict_get(w_params, key)
    if (v%kind == DYN_K_STR) then
      out = to_lower(v%s)
    else
      out = default
    end if
  end function pstr

  subroutine vec_of(v, pos, found)
    type(dyn), intent(in) :: v
    real(real64), intent(out) :: pos(3)
    logical, intent(out) :: found
    integer :: m
    type(dyn) :: e
    pos = 0.0_real64
    found = .false.
    if (v%kind /= DYN_K_LIST .or. dyn_list_len(v) < 3) return
    do m = 1, 3
      e = dyn_list_at(v, m)
      select case (e%kind)
      case (DYN_K_INT)
        pos(m) = real(e%i, real64)
      case (DYN_K_REAL)
        pos(m) = e%r
      case default
        return
      end select
    end do
    found = .true.
  end subroutine vec_of

  subroutine lookup_other(name, pos, found)
    character(*), intent(in) :: name
    real(real64), intent(out) :: pos(3)
    logical, intent(out) :: found
    integer :: j
    type(dyn) :: entry, nv
    pos = 0.0_real64
    found = .false.
    do j = 1, dyn_list_len(w_others)
      entry = dyn_list_at(w_others, j)
      nv = dyn_dict_get(entry, "name")
      if (nv%kind /= DYN_K_STR .or. nv%s /= name) cycle
      call vec_of(dyn_dict_get(entry, "pos"), pos, found)
      return
    end do
  end subroutine lookup_other

  !> Resolve a destination param ("to" / "target" / ...): a
  !! "<key>_pos" vec wins, then a direct vec under "<key>", then
  !! a name under "<key>" looked up among the scene's declared
  !! characters.  NAME_OUT receives the authored name when the
  !! param was one ("" for a raw vec / absent param).
  subroutine dest_pos(key, pos, found, name_out)
    character(*), intent(in) :: key
    real(real64), intent(out) :: pos(3)
    logical, intent(out) :: found
    character(:), allocatable, intent(out) :: name_out
    type(dyn) :: v
    pos = 0.0_real64
    found = .false.
    name_out = ""
    call vec_of(dyn_dict_get(w_params, key // "_pos"), pos, &
                found)
    if (found) then
      v = dyn_dict_get(w_params, key)
      if (v%kind == DYN_K_STR) name_out = v%s
      return
    end if
    v = dyn_dict_get(w_params, key)
    call vec_of(v, pos, found)
    if (found) return
    if (v%kind == DYN_K_STR) then
      name_out = v%s
      call lookup_other(v%s, pos, found)
    end if
  end subroutine dest_pos

  ! ---------------------------------------------------------------
  ! Sorting / de-duplication: keys sorted by (frame, channel);
  !! a repeated (frame, channel) keeps the LAST authored key;
  !! the temporary "_ord" field is stripped; the first key's
  !! ease is emitted as "linear" (TIMELINE-FORMAT).
  ! ---------------------------------------------------------------
  subroutine finish_keys(keys)
    type(dyn), intent(out) :: keys
    type(dyn) :: sorted, a, b
    integer :: n, i, j
    n = dyn_list_len(w_keys)
    sorted = dyn_list()
    do i = 1, n
      call dyn_list_push(sorted, dyn_list_at(w_keys, i))
    end do
    do i = 2, n
      a = dyn_list_at(sorted, i)
      j = i - 1
      do while (j >= 1)
        b = dyn_list_at(sorted, j)
        if (.not. key_less(a, b)) exit
        call dyn_list_set_at(sorted, j + 1, b)
        j = j - 1
      end do
      call dyn_list_set_at(sorted, j + 1, a)
    end do
    keys = dyn_list()
    do i = 1, n
      a = dyn_list_at(sorted, i)
      if (i < n) then
        b = dyn_list_at(sorted, i + 1)
        if (key_frame(a) == key_frame(b) .and. &
            key_channel(a) == key_channel(b)) cycle
      end if
      call dyn_dict_remove(a, "_ord")
      call dyn_list_push(keys, a)
    end do
    if (dyn_list_len(keys) > 0) then
      a = dyn_list_at(keys, 1)
      call dyn_dict_set(a, "ease", dyn_str("linear"))
      call dyn_list_set_at(keys, 1, a)
    end if
  end subroutine finish_keys

  integer(int64) function key_frame(k) result(fr)
    type(dyn), intent(in) :: k
    type(dyn) :: v
    v = dyn_dict_get(k, "frame")
    if (v%kind == DYN_K_INT) then
      fr = v%i
    else
      fr = -1_int64
    end if
  end function key_frame

  function key_channel(k) result(ch)
    type(dyn), intent(in) :: k
    character(:), allocatable :: ch
    type(dyn) :: v
    v = dyn_dict_get(k, "channel")
    if (v%kind == DYN_K_STR) then
      ch = v%s
    else
      ch = ""
    end if
  end function key_channel

  integer(int64) function key_ord(k) result(o)
    type(dyn), intent(in) :: k
    type(dyn) :: v
    v = dyn_dict_get(k, "_ord")
    if (v%kind == DYN_K_INT) then
      o = v%i
    else
      o = 0_int64
    end if
  end function key_ord

  logical function key_less(a, b) result(less)
    type(dyn), intent(in) :: a, b
    character(:), allocatable :: ca, cb
    less = .false.
    if (key_frame(a) /= key_frame(b)) then
      less = key_frame(a) < key_frame(b)
      return
    end if
    ca = key_channel(a)
    cb = key_channel(b)
    if (ca /= cb) then
      less = ca < cb
      return
    end if
    less = key_ord(a) < key_ord(b)
  end function key_less

end module f3dc_anim_resolve
