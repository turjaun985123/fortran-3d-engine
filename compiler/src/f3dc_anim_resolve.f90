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
! (x, y, z + current face.expr) in/out: walk/run/enter/exit move
! it, sit/stand/fall move its y, smile/face move the expression.
! The emitter owns the cursor table (reset per scene to the
! declaration position); this module only reads and updates the
! one character's entry.
!
! A verb resolves only when the character's plugin publishes a
! template for it (f3dc_plugins: plugin_template_id).  The
! stickman plugin publishes templates for all 20 of its verbs;
! the humanoid skeleton publishes none, and the core verbs
! (spin/bob/pulse/orbit/move/turn/grow) are not plugin templates
! at all -- all of those report resolved=.false. and the emitter
! keeps its Wave-2 output for the track.
module f3dc_anim_resolve
  use, intrinsic :: iso_fortran_env, only: int64, real64
  use f3dc_dyn, only: dyn, dyn_null, dyn_int, dyn_real, dyn_str, &
       dyn_list, dyn_dict, dyn_copy, dyn_assign, dyn_list_push, &
       dyn_list_len, &
       dyn_list_at, dyn_list_set_at, dyn_dict_get, dyn_dict_set, &
       dyn_dict_has, dyn_dict_remove, DYN_K_INT, DYN_K_REAL, &
       DYN_K_STR, DYN_K_LIST, DYN_K_DICT
  use f3dc_plugins, only: plugin_template_id, &
       plugin_rig_channel_form, TPL_NONE, TPL_WALK, TPL_RUN, &
       TPL_ENTER, TPL_WAVE, TPL_SIT, TPL_STAND, TPL_JUMP, &
       TPL_FALL, TPL_LOOK, TPL_FACE, TPL_POINT, TPL_NOD, &
       TPL_SHAKE, TPL_DANCE, TPL_SLEEP, TPL_SMILE, TPL_PICK, &
       TPL_GIVE, TPL_TAP, TPL_EXIT
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

contains

  ! ---------------------------------------------------------------
  ! Entry point.  CURSOR (in/out) is the character's root
  ! position; EXPR (in/out) its current face.expr code.  DECL is
  ! the declaration position.  OTHERS is a dyn list of
  ! {name, pos} dicts: every character declared in the scene,
  ! for target-by-name lookups.  On success KEYS is the sorted,
  ! de-duplicated key list and RESOLVED is true; on failure KEYS
  ! is empty and RESOLVED is false.
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
    integer :: tpl
    keys = dyn_list()
    resolved = .false.
    tpl = plugin_template_id(plugin_id, verb)
    if (tpl == TPL_NONE) return
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
    w_keys = dyn_list()
    w_ord = 0
    select case (tpl)
    case (TPL_WALK)
      call gait_move(1.8_real64, 28.0_real64, 18.0_real64, &
                         0.05_real64, cursor, resolved)
    case (TPL_RUN)
      call gait_move(2.6_real64, 40.0_real64, 28.0_real64, &
                         0.07_real64, cursor, resolved)
    case (TPL_ENTER)
      call enter_t(cursor, resolved)
    case (TPL_EXIT)
      call exit_t(cursor, resolved)
    case (TPL_WAVE)
      call wave_t(resolved)
    case (TPL_SIT)
      call sit_t(cursor, resolved)
    case (TPL_STAND)
      call stand_t(cursor, resolved)
    case (TPL_JUMP)
      call jump_t(cursor, resolved)
    case (TPL_FALL)
      call fall_t(cursor, resolved)
    case (TPL_SLEEP)
      call sleep_t(resolved)
    case (TPL_DANCE)
      call dance_t(cursor, resolved)
    case (TPL_NOD)
      call add_key(w_sf, "head.pitch", 0.0_real64, "linear")
      call add_key_f(0.25_real64, "head.pitch", 18.0_real64, &
                     "smooth")
      call add_key_f(0.5_real64, "head.pitch", 0.0_real64, &
                     "smooth")
      call add_key_f(0.75_real64, "head.pitch", 18.0_real64, &
                     "smooth")
      call add_key(w_ef, "head.pitch", 0.0_real64, "smooth")
      resolved = .true.
    case (TPL_SHAKE)
      call add_key(w_sf, "head.yaw", 0.0_real64, "linear")
      call add_key_f(1.0_real64 / 3.0_real64, "head.yaw", &
                     -20.0_real64, "smooth")
      call add_key_f(2.0_real64 / 3.0_real64, "head.yaw", &
                     20.0_real64, "smooth")
      call add_key(w_ef, "head.yaw", 0.0_real64, "smooth")
      resolved = .true.
    case (TPL_LOOK)
      call look_t(cursor, resolved)
    case (TPL_POINT)
      call point_t(cursor, resolved)
    case (TPL_FACE)
      call face_t(cursor, expr, resolved)
    case (TPL_SMILE)
      call expr_t(1.0_real64, expr, resolved)
    case (TPL_PICK)
      call pick_t(cursor, resolved)
    case (TPL_GIVE)
      call give_t(resolved)
    case (TPL_TAP)
      block
        integer :: cyc
        cyc = cycles_at(3.0_real64)
        call osc("leg.r.thigh", -6.0_real64, 6.0_real64, cyc, &
                 0.0_real64)
        resolved = .true.
      end block
    case default
      resolved = .false.
    end select
    if (.not. resolved) then
      keys = dyn_list()
      return
    end if
    call finish_keys(keys)
  end subroutine anim_resolve

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

  !> Oscillation keys for one channel: value = base + amp *
  !! sin(2*pi*cycles*frac + phase), on a quarter-cycle grid,
  !! ease "smooth".
  subroutine osc(channel, base, amp, cycles, phase)
    character(*), intent(in) :: channel
    real(real64), intent(in) :: base, amp, phase
    integer, intent(in) :: cycles
    integer :: i, steps
    real(real64) :: frac
    steps = max(4 * cycles, 1)
    do i = 0, steps
      frac = real(i, real64) / real(steps, real64)
      call add_key_f(frac, channel, base + amp * &
           sin(2.0_real64 * PI * real(cycles, real64) * frac &
               + phase), "smooth")
    end do
  end subroutine osc

  integer function cycles_at(hz) result(cyc)
    real(real64), intent(in) :: hz
    cyc = max(1, nint(w_span_sec * hz))
  end function cycles_at

  !> The gait cycle shared by walk / run / enter / exit: leg
  !! swing antiphase, shin bend trailing each thigh, arm swing
  !! opposite the same-side leg, root.y bob at twice the cycle.
  subroutine gait(cycles, thigh_amp, arm_amp, bob_amp, base_y)
    integer, intent(in) :: cycles
    real(real64), intent(in) :: thigh_amp, arm_amp, bob_amp
    real(real64), intent(in) :: base_y
    integer :: i, steps
    real(real64) :: frac, ph
    call osc("leg.l.thigh", 0.0_real64, thigh_amp, cycles, &
             0.0_real64)
    call osc("leg.r.thigh", 0.0_real64, -thigh_amp, cycles, &
             0.0_real64)
    call osc("leg.l.shin", 20.0_real64, 20.0_real64, cycles, &
             -PI / 2.0_real64)
    call osc("leg.r.shin", 20.0_real64, 20.0_real64, cycles, &
             PI / 2.0_real64)
    call osc("arm.l.upper", 0.0_real64, -arm_amp, cycles, &
             0.0_real64)
    call osc("arm.r.upper", 0.0_real64, arm_amp, cycles, &
             0.0_real64)
    steps = max(4 * cycles, 1)
    do i = 0, steps
      frac = real(i, real64) / real(steps, real64)
      ph = 2.0_real64 * PI * real(cycles, real64) * frac
      call add_key_f(frac, "root.y", base_y + bob_amp * &
           (0.5_real64 - 0.5_real64 * cos(2.0_real64 * ph)), &
           "smooth")
    end do
  end subroutine gait

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
  ! Templates
  ! ---------------------------------------------------------------

  !> walk / run: root.x/z from the cursor to params.to (cue
  !! ease on the end keys) plus the gait cycle; cursor moves.
  subroutine gait_move(hz, thigh_amp, arm_amp, bob_amp, &
                           cursor, resolved)
    real(real64), intent(in) :: hz, thigh_amp, arm_amp, bob_amp
    real(real64), intent(inout) :: cursor(3)
    logical, intent(out) :: resolved
    real(real64) :: to(3)
    character(:), allocatable :: nm
    logical :: found
    resolved = .false.
    call dest_pos("to", to, found, nm)
    if (.not. found) return
    call add_key(w_sf, "root.x", cursor(1), "linear")
    call add_key(w_ef, "root.x", to(1), w_ease)
    call add_key(w_sf, "root.z", cursor(3), "linear")
    call add_key(w_ef, "root.z", to(3), w_ease)
    call gait(cycles_at(hz), thigh_amp, arm_amp, bob_amp, &
              cursor(2))
    cursor(1) = to(1)
    cursor(3) = to(3)
    resolved = .true.
  end subroutine gait_move

  !> enter: root starts at the declaration position offset by
  !! the "from" side and walks to the declaration position.
  subroutine enter_t(cursor, resolved)
    real(real64), intent(inout) :: cursor(3)
    logical, intent(out) :: resolved
    character(:), allocatable :: side
    real(real64) :: off
    resolved = .false.
    side = pstr("from", "")
    select case (side)
    case ("left")
      off = -6.0_real64
    case ("right")
      off = 6.0_real64
    case default
      return
    end select
    call add_key(w_sf, "root.x", w_decl(1) + off, "linear")
    call add_key(w_ef, "root.x", w_decl(1), w_ease)
    call add_key(w_sf, "root.z", w_decl(3), "linear")
    call add_key(w_ef, "root.z", w_decl(3), w_ease)
    call gait(cycles_at(1.8_real64), 28.0_real64, 18.0_real64, &
              0.05_real64, w_decl(2))
    cursor = w_decl
    resolved = .true.
  end subroutine enter_t

  !> exit: root walks from the cursor to the cursor plus the
  !! side offset ("direction" param; default right).
  subroutine exit_t(cursor, resolved)
    real(real64), intent(inout) :: cursor(3)
    logical, intent(out) :: resolved
    character(:), allocatable :: side
    real(real64) :: off
    resolved = .false.
    side = pstr("direction", "right")
    select case (side)
    case ("left")
      off = -6.0_real64
    case ("right")
      off = 6.0_real64
    case default
      return
    end select
    call add_key(w_sf, "root.x", cursor(1), "linear")
    call add_key(w_ef, "root.x", cursor(1) + off, w_ease)
    call add_key(w_sf, "root.z", cursor(3), "linear")
    call add_key(w_ef, "root.z", cursor(3), w_ease)
    call gait(cycles_at(1.8_real64), 28.0_real64, 18.0_real64, &
              0.05_real64, cursor(2))
    cursor(1) = cursor(1) + off
    resolved = .true.
  end subroutine exit_t

  subroutine wave_arm(prefix, sign, cycles)
    character(*), intent(in) :: prefix
    real(real64), intent(in) :: sign
    integer, intent(in) :: cycles
    integer :: i, steps
    real(real64) :: frac
    call add_key(w_sf, prefix // ".upper", 0.0_real64, "linear")
    call add_key_f(0.2_real64, prefix // ".upper", &
                   sign * 150.0_real64, w_ease)
    call add_key(w_ef, prefix // ".upper", sign * 150.0_real64, &
                 "smooth")
    steps = max(4 * cycles, 1)
    do i = 0, steps
      frac = 0.2_real64 + 0.8_real64 * real(i, real64) &
             / real(steps, real64)
      call add_key_f(frac, prefix // ".fore", 25.0_real64 * &
           sin(2.0_real64 * PI * real(cycles, real64) &
               * real(i, real64) / real(steps, real64)), "smooth")
    end do
  end subroutine wave_arm

  !> wave: the chosen arm raises (right +150 / left -150, held)
  !! while its forearm oscillates +-25.  Arm from params "arm",
  !! falling back to the authored "hand" param; cycles from
  !! params or max(1, round(span_seconds * 1.2)).
  subroutine wave_t(resolved)
    logical, intent(out) :: resolved
    character(:), allocatable :: arm
    integer :: cyc
    type(dyn) :: v
    resolved = .false.
    arm = pstr("arm", "")
    if (len(arm) == 0) arm = pstr("hand", "right")
    v = dyn_dict_get(w_params, "cycles")
    if (v%kind == DYN_K_INT) then
      cyc = max(1, int(v%i))
    else if (v%kind == DYN_K_REAL) then
      cyc = max(1, nint(v%r))
    else
      cyc = max(1, nint(w_span_sec * 1.2_real64))
    end if
    select case (arm)
    case ("right")
      call wave_arm("arm.r", 1.0_real64, cyc)
    case ("left")
      call wave_arm("arm.l", -1.0_real64, cyc)
    case ("both")
      call wave_arm("arm.r", 1.0_real64, cyc)
      call wave_arm("arm.l", -1.0_real64, cyc)
    case default
      return
    end select
    resolved = .true.
  end subroutine wave_t

  subroutine sit_t(cursor, resolved)
    real(real64), intent(inout) :: cursor(3)
    logical, intent(out) :: resolved
    call add_key(w_sf, "root.y", cursor(2), "linear")
    call add_key(w_ef, "root.y", 0.5_real64, w_ease)
    call add_key(w_sf, "leg.l.thigh", 0.0_real64, "linear")
    call add_key(w_ef, "leg.l.thigh", -90.0_real64, w_ease)
    call add_key(w_sf, "leg.r.thigh", 0.0_real64, "linear")
    call add_key(w_ef, "leg.r.thigh", -90.0_real64, w_ease)
    call add_key(w_sf, "leg.l.shin", 0.0_real64, "linear")
    call add_key(w_ef, "leg.l.shin", 90.0_real64, w_ease)
    call add_key(w_sf, "leg.r.shin", 0.0_real64, "linear")
    call add_key(w_ef, "leg.r.shin", 90.0_real64, w_ease)
    call add_key(w_sf, "torso", 0.0_real64, "linear")
    call add_key(w_ef, "torso", 5.0_real64, w_ease)
    cursor(2) = 0.5_real64
    resolved = .true.
  end subroutine sit_t

  !> stand: root.y returns to the declaration ground y; the
  !! legs leave the sit pose (thigh -90 / shin +90 / torso +5)
  !! for neutral.
  subroutine stand_t(cursor, resolved)
    real(real64), intent(inout) :: cursor(3)
    logical, intent(out) :: resolved
    call add_key(w_sf, "root.y", cursor(2), "linear")
    call add_key(w_ef, "root.y", w_decl(2), w_ease)
    call add_key(w_sf, "leg.l.thigh", -90.0_real64, "linear")
    call add_key(w_ef, "leg.l.thigh", 0.0_real64, w_ease)
    call add_key(w_sf, "leg.r.thigh", -90.0_real64, "linear")
    call add_key(w_ef, "leg.r.thigh", 0.0_real64, w_ease)
    call add_key(w_sf, "leg.l.shin", 90.0_real64, "linear")
    call add_key(w_ef, "leg.l.shin", 0.0_real64, w_ease)
    call add_key(w_sf, "leg.r.shin", 90.0_real64, "linear")
    call add_key(w_ef, "leg.r.shin", 0.0_real64, w_ease)
    call add_key(w_sf, "torso", 5.0_real64, "linear")
    call add_key(w_ef, "torso", 0.0_real64, w_ease)
    cursor(2) = w_decl(2)
    resolved = .true.
  end subroutine stand_t

  !> jump: root.y parabola peaking at +0.55 mid-span; legs
  !! tuck and both arms raise at the peak.
  subroutine jump_t(cursor, resolved)
    real(real64), intent(inout) :: cursor(3)
    logical, intent(out) :: resolved
    real(real64) :: fr(5)
    integer :: i
    fr = [0.0_real64, 0.25_real64, 0.5_real64, 0.75_real64, &
          1.0_real64]
    do i = 1, 5
      call add_key_f(fr(i), "root.y", cursor(2) &
           + 0.55_real64 * 4.0_real64 * fr(i) &
           * (1.0_real64 - fr(i)), "smooth")
    end do
    call add_key(w_sf, "leg.l.thigh", 0.0_real64, "linear")
    call add_key_f(0.5_real64, "leg.l.thigh", -30.0_real64, &
                   "smooth")
    call add_key(w_ef, "leg.l.thigh", 0.0_real64, "smooth")
    call add_key(w_sf, "leg.r.thigh", 0.0_real64, "linear")
    call add_key_f(0.5_real64, "leg.r.thigh", -30.0_real64, &
                   "smooth")
    call add_key(w_ef, "leg.r.thigh", 0.0_real64, "smooth")
    call add_key(w_sf, "leg.l.shin", 0.0_real64, "linear")
    call add_key_f(0.5_real64, "leg.l.shin", 55.0_real64, &
                   "smooth")
    call add_key(w_ef, "leg.l.shin", 0.0_real64, "smooth")
    call add_key(w_sf, "leg.r.shin", 0.0_real64, "linear")
    call add_key_f(0.5_real64, "leg.r.shin", 55.0_real64, &
                   "smooth")
    call add_key(w_ef, "leg.r.shin", 0.0_real64, "smooth")
    call add_key(w_sf, "arm.r.upper", 0.0_real64, "linear")
    call add_key_f(0.5_real64, "arm.r.upper", 150.0_real64, &
                   "smooth")
    call add_key(w_ef, "arm.r.upper", 0.0_real64, "smooth")
    call add_key(w_sf, "arm.l.upper", 0.0_real64, "linear")
    call add_key_f(0.5_real64, "arm.l.upper", -150.0_real64, &
                   "smooth")
    call add_key(w_ef, "arm.l.upper", 0.0_real64, "smooth")
    resolved = .true.
  end subroutine jump_t

  subroutine fall_t(cursor, resolved)
    real(real64), intent(inout) :: cursor(3)
    logical, intent(out) :: resolved
    call add_key(w_sf, "torso", 0.0_real64, "linear")
    call add_key(w_ef, "torso", 88.0_real64, "cubic-in")
    call add_key(w_sf, "root.y", cursor(2), "linear")
    call add_key(w_ef, "root.y", 0.1_real64, "cubic-in")
    call add_key(w_sf, "leg.l.thigh", 0.0_real64, "linear")
    call add_key(w_ef, "leg.l.thigh", -10.0_real64, "cubic-in")
    call add_key(w_sf, "leg.r.thigh", 0.0_real64, "linear")
    call add_key(w_ef, "leg.r.thigh", -10.0_real64, "cubic-in")
    call add_key(w_sf, "leg.l.shin", 0.0_real64, "linear")
    call add_key(w_ef, "leg.l.shin", 15.0_real64, "cubic-in")
    call add_key(w_sf, "leg.r.shin", 0.0_real64, "linear")
    call add_key(w_ef, "leg.r.shin", 15.0_real64, "cubic-in")
    cursor(2) = 0.1_real64
    resolved = .true.
  end subroutine fall_t

  subroutine sleep_t(resolved)
    logical, intent(out) :: resolved
    call add_key(w_sf, "torso", 0.0_real64, "linear")
    call add_key(w_ef, "torso", 80.0_real64, "cubic-in-out")
    call add_key(w_sf, "head.pitch", 0.0_real64, "linear")
    call add_key(w_ef, "head.pitch", 15.0_real64, &
                 "cubic-in-out")
    resolved = .true.
  end subroutine sleep_t

  !> dance: 2 Hz cycles -- arms alternate between raised and
  !! rest, torso/head/thighs sway, root.y bounces.
  subroutine dance_t(cursor, resolved)
    real(real64), intent(inout) :: cursor(3)
    logical, intent(out) :: resolved
    integer :: cyc, i, steps
    real(real64) :: frac, ph, s
    cyc = cycles_at(2.0_real64)
    steps = max(4 * cyc, 1)
    do i = 0, steps
      frac = real(i, real64) / real(steps, real64)
      ph = 2.0_real64 * PI * real(cyc, real64) * frac
      s = sin(ph)
      call add_key_f(frac, "arm.r.upper", &
                     75.0_real64 + 75.0_real64 * s, "smooth")
      call add_key_f(frac, "arm.l.upper", &
                     -75.0_real64 + 75.0_real64 * s, "smooth")
      call add_key_f(frac, "torso", 8.0_real64 * s, "smooth")
      call add_key_f(frac, "leg.l.thigh", 20.0_real64 * s, &
                     "smooth")
      call add_key_f(frac, "leg.r.thigh", -20.0_real64 * s, &
                     "smooth")
      call add_key_f(frac, "head.yaw", 10.0_real64 * s, &
                     "smooth")
      call add_key_f(frac, "root.y", cursor(2) &
                     + 0.06_real64 * abs(s), "smooth")
    end do
    resolved = .true.
  end subroutine dance_t

  !> look: head.yaw turns toward the target's side (+-25).
  subroutine look_t(cursor, resolved)
    real(real64), intent(inout) :: cursor(3)
    logical, intent(out) :: resolved
    real(real64) :: to(3), yaw
    character(:), allocatable :: nm
    logical :: found
    resolved = .false.
    call dest_pos("target", to, found, nm)
    if (.not. found) return
    if (to(1) < cursor(1)) then
      yaw = -25.0_real64
    else if (to(1) > cursor(1)) then
      yaw = 25.0_real64
    else
      yaw = 0.0_real64
    end if
    call add_key(w_sf, "head.yaw", 0.0_real64, "linear")
    call add_key(w_ef, "head.yaw", yaw, w_ease)
    resolved = .true.
  end subroutine look_t

  !> point: the arm on the target's side raises to +-90; the
  !! head turns the same way by 15.
  subroutine point_t(cursor, resolved)
    real(real64), intent(inout) :: cursor(3)
    logical, intent(out) :: resolved
    real(real64) :: to(3), sgn
    character(:), allocatable :: nm, arm_ch
    logical :: found
    resolved = .false.
    call dest_pos("target", to, found, nm)
    if (.not. found) return
    if (to(1) < cursor(1)) then
      sgn = -1.0_real64
      arm_ch = "arm.l.upper"
    else
      sgn = 1.0_real64
      arm_ch = "arm.r.upper"
    end if
    call add_key(w_sf, arm_ch, 0.0_real64, "linear")
    call add_key(w_ef, arm_ch, sgn * 90.0_real64, w_ease)
    call add_key(w_sf, "head.yaw", 0.0_real64, "linear")
    call add_key(w_ef, "head.yaw", sgn * 15.0_real64, w_ease)
    resolved = .true.
  end subroutine point_t

  !> An expression change: one key at the span start carrying
  !! the new face.expr code, plus an end key with the same
  !! value easing "hold".  The expression cursor moves.
  subroutine expr_t(code, expr, resolved)
    real(real64), intent(in) :: code
    real(real64), intent(inout) :: expr
    logical, intent(out) :: resolved
    call add_key(w_sf, "face.expr", code, "linear")
    call add_key(w_ef, "face.expr", code, "hold")
    expr = code
    resolved = .true.
  end subroutine expr_t

  subroutine expr_code(name, code, found)
    character(*), intent(in) :: name
    real(real64), intent(out) :: code
    logical, intent(out) :: found
    code = 0.0_real64
    found = .true.
    select case (name)
    case ("neutral")
      code = 0.0_real64
    case ("happy")
      code = 1.0_real64
    case ("sad")
      code = 2.0_real64
    case ("determined")
      code = 3.0_real64
    case ("surprised")
      code = 4.0_real64
    case default
      found = .false.
    end select
  end subroutine expr_code

  !> face: with an "expression" param it is an expression
  !! change; otherwise root.face yaws toward the target,
  !! computed from positions with the default camera at +Z:
  !! offset = atan2(dx, dz) in degrees, clamped to +-180.
  !! The target "camera" faces 0.
  subroutine face_t(cursor, expr, resolved)
    real(real64), intent(inout) :: cursor(3), expr
    logical, intent(out) :: resolved
    character(:), allocatable :: ename, nm
    real(real64) :: to(3), code, yaw
    logical :: found
    resolved = .false.
    ename = pstr("expression", "")
    if (len(ename) > 0) then
      call expr_code(ename, code, found)
      if (.not. found) return
      call expr_t(code, expr, resolved)
      return
    end if
    call dest_pos("target", to, found, nm)
    if (nm == "camera") then
      yaw = 0.0_real64
    else if (found) then
      yaw = atan2(to(1) - cursor(1), to(3) - cursor(3)) &
            * 180.0_real64 / PI
      yaw = max(-180.0_real64, min(180.0_real64, yaw))
    else if (.not. dyn_dict_has(w_params, "target") .and. &
             .not. dyn_dict_has(w_params, "target_pos")) then
      ! No target information reached the params at all: the
      ! authored target was "camera", whose name the fragment
      ! does not carry (only target positions survive) -- the
      ! character faces the camera, yaw 0.
      yaw = 0.0_real64
    else
      return
    end if
    call add_key(w_sf, "root.face", 0.0_real64, "linear")
    call add_key(w_ef, "root.face", yaw, w_ease)
    resolved = .true.
  end subroutine face_t

  !> pick: torso leans +25 and root.y dips to x0.85 mid-span;
  !! the right arm reaches +60 then settles to +20.
  subroutine pick_t(cursor, resolved)
    real(real64), intent(inout) :: cursor(3)
    logical, intent(out) :: resolved
    call add_key(w_sf, "torso", 0.0_real64, "linear")
    call add_key_f(0.5_real64, "torso", 25.0_real64, "smooth")
    call add_key(w_ef, "torso", 0.0_real64, w_ease)
    call add_key(w_sf, "arm.r.upper", 0.0_real64, "linear")
    call add_key_f(0.5_real64, "arm.r.upper", 60.0_real64, &
                   "smooth")
    call add_key(w_ef, "arm.r.upper", 20.0_real64, w_ease)
    call add_key(w_sf, "root.y", cursor(2), "linear")
    call add_key_f(0.5_real64, "root.y", cursor(2) &
                   * 0.85_real64, "smooth")
    call add_key(w_ef, "root.y", cursor(2), w_ease)
    resolved = .true.
  end subroutine pick_t

  !> give: both arms reach +70 and the torso leans +10,
  !! mid-span, returning by the end.
  subroutine give_t(resolved)
    logical, intent(out) :: resolved
    call add_key(w_sf, "arm.r.upper", 0.0_real64, "linear")
    call add_key_f(0.5_real64, "arm.r.upper", 70.0_real64, &
                   "smooth")
    call add_key(w_ef, "arm.r.upper", 0.0_real64, w_ease)
    call add_key(w_sf, "arm.l.upper", 0.0_real64, "linear")
    call add_key_f(0.5_real64, "arm.l.upper", 70.0_real64, &
                   "smooth")
    call add_key(w_ef, "arm.l.upper", 0.0_real64, w_ease)
    call add_key(w_sf, "torso", 0.0_real64, "linear")
    call add_key_f(0.5_real64, "torso", 10.0_real64, "smooth")
    call add_key(w_ef, "torso", 0.0_real64, w_ease)
    resolved = .true.
  end subroutine give_t

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
