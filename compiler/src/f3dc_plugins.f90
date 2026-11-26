! f3dc_plugins.f90 -- Forge3D plugin registry (ANIM Wave 2, slice A1).
!
! The all-rounder scope correction (docs/ANIM-WAVES.md, user ruling
! 2026-11-26): Forge3D is NOT a stickman compiler.  The core
! language / compiler / Timeline IR stay rig- and character-type
! agnostic; character rigs, action sets and feature packs register
! as PLUGINS.  The stickman engine is the first plugin (id
! "stickman") -- a proof case, not a core assumption.
!
! This module is a LEAF: it depends only on f3dc_dyn / f3dc_str, so
! every stage (parser, desugar, validator, fmt via the CLI) can
! query it without a dependency cycle.  It holds the registry of
! plugin records.  A plugin declares:
!
!   * id            -- its stable identifier ("stickman").
!   * channels      -- the rig channel ids it owns ("body", "face").
!   * verbs         -- its action verb set; every spelling maps to
!                      the channel that verb animates.
!   * prop schema   -- character prop name -> kind, so character
!                      prop parsing/validation is data-driven:
!                      kind is one of
!                        "flag"       a bare word (its surface word
!                                     IS the value; several flag
!                                     entries may share one prop
!                                     name -- the alternatives of
!                                     one prop, e.g. proportions)
!                        "enum"       one word from an allowed list
!                        "word"       one word, stored lower-cased
!                        "free"       one word/name, stored verbatim
!                        "number"     one number
!                        "colour"     one colour value
!                        "itemcolour" an item word + optional colour;
!                                     repeatable, accumulates a list
!                                     of {item, colour} dicts
!                      A schema entry also carries the SURFACE word
!                      that introduces it in a character line (for
!                      "flag" entries the surface word differs from
!                      the prop name; for all other kinds they are
!                      the same word) and whether it may repeat.
!   * capabilities  -- named abilities other stages ask about
!                      instead of hardcoding rules (e.g. "speaks":
!                      characters of this plugin may speak dialogue,
!                      ANIM-PLAN SS2.4 E211).
!
! Registration is LAZY and IDEMPOTENT: every public query calls
! ensure_plugins() first, which registers the built-ins exactly
! once.  That way ALL entry points (build / check / fmt, the typed
! and dyn pipelines alike) see a populated registry without any
! stage owning an init call.
!
! Wave 3 (slice S1): plugins also publish a RIG-CHANNEL
! vocabulary -- the per-channel key names a resolved action track
! may carry in the Timeline IR -- plus, per verb, a TEMPLATE id
! naming the resolver template that turns the verb into keys
! (0 = none: the verb stays unresolved).  The resolver itself
! lives in f3dc_anim_resolve; this module only holds the data.
!
! The stickman rig-channel vocabulary (published; see
! docs/PLUGINS.md):
!   root.x, root.y, root.z   (value, world units)
!   root.face                (value_deg, yaw offset)
!   torso                    (value_deg, in-plane tilt)
!   head.pitch, head.yaw     (value_deg)
!   arm.l.upper, arm.l.fore, arm.r.upper, arm.r.fore (value_deg)
!   leg.l.thigh, leg.l.shin, leg.r.thigh, leg.r.shin (value_deg)
!   face.expr                (value; 0 neutral, 1 happy, 2 sad,
!                             3 determined, 4 surprised)
! Angle convention: 0 = limb hanging straight down; positive
! rotates the down-vector toward the character's right (+u in
! the figure plane).  A right-arm raise (wave) is therefore
! arm.r.upper -> +150 and a left-arm raise arm.l.upper -> -150.
!
! ease_canonical() also lives here: the single spelling authority
! for easing names (Wave-2 must-fix flag 6, ANIM-PLAN SS3.4).  The
! canonical set is: linear, smooth, in, out, cubic-in, cubic-out,
! cubic-in-out, bezier(...), hold.  The alias spellings ease-in /
! ease-out / ease-in-out and the sentence adverbs slowly / gently
! map onto it; every other name passes through unchanged.
module f3dc_plugins
  use f3dc_str, only: char_list, char_list_append, char_list_len, &
       char_list_at, to_lower, str_builder, sb_init, sb_add, &
       sb_text, sb_len, int_list, int_list_append, int_list_len, &
       int_list_at
  use, intrinsic :: iso_fortran_env, only: int64
  use f3dc_dyn, only: dyn, dyn_dict, dyn_str, dyn_null, dyn_copy, &
       dyn_assign, dyn_dict_set, DYN_K_NULL
  implicit none
  private

  public :: plugin_default_id
  public :: plugin_exists
  public :: plugin_capability
  public :: plugin_rig
  public :: plugin_is_verb
  public :: plugin_channel_for_verb
  public :: plugin_verb_channel
  public :: plugin_prop_by_surface
  public :: plugin_prop_by_name
  public :: plugin_prop_value_ok
  public :: plugin_prop_allowed_csv
  public :: plugin_prop_names_csv
  public :: plugin_rig_channel_count
  public :: plugin_rig_channel_at
  public :: plugin_rig_channel_form
  public :: plugin_template_id
  public :: ease_canonical

  ! Resolver template ids (per-verb, parallel to the verb list;
  ! TPL_NONE = the verb has no template and stays unresolved).
  integer, parameter, public :: TPL_NONE = 0
  integer, parameter, public :: TPL_WALK = 1
  integer, parameter, public :: TPL_RUN = 2
  integer, parameter, public :: TPL_ENTER = 3
  integer, parameter, public :: TPL_WAVE = 4
  integer, parameter, public :: TPL_SIT = 5
  integer, parameter, public :: TPL_STAND = 6
  integer, parameter, public :: TPL_JUMP = 7
  integer, parameter, public :: TPL_FALL = 8
  integer, parameter, public :: TPL_LOOK = 9
  integer, parameter, public :: TPL_FACE = 10
  integer, parameter, public :: TPL_POINT = 11
  integer, parameter, public :: TPL_NOD = 12
  integer, parameter, public :: TPL_SHAKE = 13
  integer, parameter, public :: TPL_DANCE = 14
  integer, parameter, public :: TPL_SLEEP = 15
  integer, parameter, public :: TPL_SMILE = 16
  integer, parameter, public :: TPL_PICK = 17
  integer, parameter, public :: TPL_GIVE = 18
  integer, parameter, public :: TPL_TAP = 19
  integer, parameter, public :: TPL_EXIT = 20

  integer, parameter :: MAX_PLUGINS = 16
  integer, parameter :: MAX_PROPS = 32

  type :: prop_rec
    character(32) :: name = ""
    character(16) :: kind = ""
    character(32) :: surface = ""
    character(256) :: allowed = ""  ! comma-joined enum values
    logical :: multi = .false.
    logical :: lower = .true.
  end type prop_rec

  type :: plugin_rec
    character(32) :: id = ""
    type(dyn) :: rig  ! plugin-owned rig description (Timeline IR
                      ! Character "rig" payload), a dyn dict; null
                      ! when the plugin declares none.
    type(char_list) :: channels
    type(char_list) :: verbs
    type(char_list) :: verb_channels  ! parallel to verbs
    type(int_list) :: verb_templates  ! parallel to verbs; TPL_*
    type(char_list) :: rig_channels   ! published rig channels
    type(char_list) :: rig_ch_forms   ! parallel: "deg" | "value"
    type(char_list) :: caps
    type(prop_rec) :: props(MAX_PROPS)
    integer :: nprops = 0
  end type plugin_rec

  type(plugin_rec) :: plugins(MAX_PLUGINS)
  integer :: n_plugins = 0
  logical :: plugins_ready = .false.

contains

  ! ---------------------------------------------------------------
  ! Registration (built-ins).  Idempotent: a second call is a no-op.
  ! ---------------------------------------------------------------
  subroutine ensure_plugins()
    integer :: p
    if (plugins_ready) return
    plugins_ready = .true.
    ! The stickman plugin: EXACTLY Wave 1's behaviour, as data.
    ! Channels/verbs/channels-per-verb mirror the old core tables
    ! (ANIM_KINDS_EXT in f3dc_val_common, tl_channel in
    ! f3dc_desugar); the prop schema mirrors the old core branches
    ! of parse_character in f3dc_parser.
    p = add_plugin("stickman")
    ! The stickman rig description, as published for the Timeline
    ! IR (docs/TIMELINE-FORMAT.md, Character "rig"): plugin-owned
    ! vocabulary, carried opaquely by the core format.
    block
      type(dyn) :: rig
      rig = dyn_dict()
      call dyn_dict_set(rig, "kind", dyn_str("stick"))
      call dyn_dict_set(rig, "topology", dyn_str("humanoid11"))
      call dyn_assign(plugins(p)%rig, rig)
    end block
    call char_list_append(plugins(p)%channels, "body")
    call char_list_append(plugins(p)%channels, "face")
    call char_list_append(plugins(p)%caps, "speaks")
    ! Verb set = the Wave-1 ANIM_KINDS_EXT list (canonical "-s"
    ! forms and their base-form aliases).  smile/face animate the
    ! "face" channel; everything else animates "body".
    call reg_verbs(p, "walks", "walk", "body", TPL_WALK)
    call reg_verbs(p, "runs", "run", "body", TPL_RUN)
    call reg_verbs(p, "enters", "enter", "body", TPL_ENTER)
    call reg_verbs(p, "waves", "wave", "body", TPL_WAVE)
    call reg_verbs(p, "sits", "sit", "body", TPL_SIT)
    call reg_verbs(p, "stands", "stand", "body", TPL_STAND)
    call reg_verbs(p, "jumps", "jump", "body", TPL_JUMP)
    call reg_verbs(p, "falls", "fall", "body", TPL_FALL)
    call reg_verbs(p, "looks", "look", "body", TPL_LOOK)
    call reg_verbs(p, "faces", "face", "face", TPL_FACE)
    call reg_verbs(p, "points", "point", "body", TPL_POINT)
    call reg_verbs(p, "nods", "nod", "body", TPL_NOD)
    call reg_verbs(p, "shakes", "shake", "body", TPL_SHAKE)
    call reg_verbs(p, "dances", "dance", "body", TPL_DANCE)
    call reg_verbs(p, "sleeps", "sleep", "body", TPL_SLEEP)
    call reg_verbs(p, "smiles", "smile", "face", TPL_SMILE)
    call reg_verbs(p, "picks", "pick", "body", TPL_PICK)
    call reg_verbs(p, "gives", "give", "body", TPL_GIVE)
    call reg_verbs(p, "taps", "tap", "body", TPL_TAP)
    call reg_verbs(p, "exits", "exit", "body", TPL_EXIT)
    ! The published rig-channel vocabulary (see the header).
    call reg_rig_channel(p, "root.x", "value")
    call reg_rig_channel(p, "root.y", "value")
    call reg_rig_channel(p, "root.z", "value")
    call reg_rig_channel(p, "root.face", "deg")
    call reg_rig_channel(p, "torso", "deg")
    call reg_rig_channel(p, "head.pitch", "deg")
    call reg_rig_channel(p, "head.yaw", "deg")
    call reg_rig_channel(p, "arm.l.upper", "deg")
    call reg_rig_channel(p, "arm.l.fore", "deg")
    call reg_rig_channel(p, "arm.r.upper", "deg")
    call reg_rig_channel(p, "arm.r.fore", "deg")
    call reg_rig_channel(p, "leg.l.thigh", "deg")
    call reg_rig_channel(p, "leg.l.shin", "deg")
    call reg_rig_channel(p, "leg.r.thigh", "deg")
    call reg_rig_channel(p, "leg.r.shin", "deg")
    call reg_rig_channel(p, "face.expr", "value")
    ! Character prop schema (ANIM-PLAN SS1.2), in declaration
    ! order.  `proportions` is one prop with three flag surface
    ! words; `height` is its numeric escape hatch.
    call add_prop(p, "proportions", "flag", "tall", "", &
                  .false., .true.)
    call add_prop(p, "proportions", "flag", "short", "", &
                  .false., .true.)
    call add_prop(p, "proportions", "flag", "kid", "", &
                  .false., .true.)
    call add_prop(p, "height", "number", "height", "", &
                  .false., .true.)
    call add_prop(p, "head", "enum", "head", &
                  "round,square,oval", .false., .true.)
    call add_prop(p, "hair", "word", "hair", "", .false., .true.)
    call add_prop(p, "face", "enum", "face", &
                  "happy,sad,determined,surprised,neutral", &
                  .false., .true.)
    call add_prop(p, "wears", "itemcolour", "wears", "", &
                  .true., .true.)
    call add_prop(p, "holds", "free", "holds", "", &
                  .false., .false.)

    ! The humanoid plugin: a SKELETON registration (Wave 3 S1).
    ! It proves the registry is plugin-shaped, not stickman-
    ! shaped: same verb set and channels, "speaks" capability,
    ! a humanoid rig description -- but NO rig channels and NO
    ! templates, so its actions stay unresolved in the IR.
    ! Its character prop schema is proportions/height only.
    p = add_plugin("humanoid")
    block
      type(dyn) :: rig
      rig = dyn_dict()
      call dyn_dict_set(rig, "kind", dyn_str("humanoid"))
      call dyn_dict_set(rig, "topology", dyn_str("humanoid11"))
      call dyn_assign(plugins(p)%rig, rig)
    end block
    call char_list_append(plugins(p)%channels, "body")
    call char_list_append(plugins(p)%channels, "face")
    call char_list_append(plugins(p)%caps, "speaks")
    call reg_verbs(p, "walks", "walk", "body", TPL_NONE)
    call reg_verbs(p, "runs", "run", "body", TPL_NONE)
    call reg_verbs(p, "enters", "enter", "body", TPL_NONE)
    call reg_verbs(p, "waves", "wave", "body", TPL_NONE)
    call reg_verbs(p, "sits", "sit", "body", TPL_NONE)
    call reg_verbs(p, "stands", "stand", "body", TPL_NONE)
    call reg_verbs(p, "jumps", "jump", "body", TPL_NONE)
    call reg_verbs(p, "falls", "fall", "body", TPL_NONE)
    call reg_verbs(p, "looks", "look", "body", TPL_NONE)
    call reg_verbs(p, "faces", "face", "face", TPL_NONE)
    call reg_verbs(p, "points", "point", "body", TPL_NONE)
    call reg_verbs(p, "nods", "nod", "body", TPL_NONE)
    call reg_verbs(p, "shakes", "shake", "body", TPL_NONE)
    call reg_verbs(p, "dances", "dance", "body", TPL_NONE)
    call reg_verbs(p, "sleeps", "sleep", "body", TPL_NONE)
    call reg_verbs(p, "smiles", "smile", "face", TPL_NONE)
    call reg_verbs(p, "picks", "pick", "body", TPL_NONE)
    call reg_verbs(p, "gives", "give", "body", TPL_NONE)
    call reg_verbs(p, "taps", "tap", "body", TPL_NONE)
    call reg_verbs(p, "exits", "exit", "body", TPL_NONE)
    call add_prop(p, "proportions", "flag", "tall", "", &
                  .false., .true.)
    call add_prop(p, "proportions", "flag", "short", "", &
                  .false., .true.)
    call add_prop(p, "proportions", "flag", "kid", "", &
                  .false., .true.)
    call add_prop(p, "height", "number", "height", "", &
                  .false., .true.)
  end subroutine ensure_plugins

  integer function add_plugin(id) result(idx)
    character(*), intent(in) :: id
    if (n_plugins >= MAX_PLUGINS) then
      idx = MAX_PLUGINS
      return
    end if
    n_plugins = n_plugins + 1
    idx = n_plugins
    plugins(idx)%id = id
  end function add_plugin

  subroutine reg_verbs(p, sform, base, channel, template)
    integer, intent(in) :: p
    character(*), intent(in) :: sform, base, channel
    integer, intent(in) :: template
    call char_list_append(plugins(p)%verbs, sform)
    call char_list_append(plugins(p)%verb_channels, channel)
    call int_list_append(plugins(p)%verb_templates, &
                         int(template, int64))
    call char_list_append(plugins(p)%verbs, base)
    call char_list_append(plugins(p)%verb_channels, channel)
    call int_list_append(plugins(p)%verb_templates, &
                         int(template, int64))
  end subroutine reg_verbs

  !> Publish one rig channel of plugin `p`: NAME plus its value
  !! form, "deg" (emitted as value_deg) or "value" (value).
  subroutine reg_rig_channel(p, name, form)
    integer, intent(in) :: p
    character(*), intent(in) :: name, form
    call char_list_append(plugins(p)%rig_channels, name)
    call char_list_append(plugins(p)%rig_ch_forms, form)
  end subroutine reg_rig_channel

  subroutine add_prop(p, name, kind, surface, allowed, multi, lower)
    integer, intent(in) :: p
    character(*), intent(in) :: name, kind, surface, allowed
    logical, intent(in) :: multi, lower
    integer :: i
    if (plugins(p)%nprops >= MAX_PROPS) return
    i = plugins(p)%nprops + 1
    plugins(p)%nprops = i
    plugins(p)%props(i)%name = name
    plugins(p)%props(i)%kind = kind
    plugins(p)%props(i)%surface = surface
    plugins(p)%props(i)%allowed = allowed
    plugins(p)%props(i)%multi = multi
    plugins(p)%props(i)%lower = lower
  end subroutine add_prop

  integer function find_plugin(id) result(idx)
    character(*), intent(in) :: id
    integer :: k
    idx = 0
    do k = 1, n_plugins
      if (trim(plugins(k)%id) == id) then
        idx = k
        return
      end if
    end do
  end function find_plugin

  logical function list_has(list, word)
    type(char_list), intent(in) :: list
    character(*), intent(in) :: word
    integer :: k
    list_has = .false.
    do k = 1, char_list_len(list)
      if (char_list_at(list, k) == word) then
        list_has = .true.
        return
      end if
    end do
  end function list_has

  ! ---------------------------------------------------------------
  ! Public queries (all ensure the registry is populated first).
  ! ---------------------------------------------------------------

  !> The plugin a character belongs to when its declaration names
  !! none: the first registered plugin.
  function plugin_default_id() result(id)
    character(:), allocatable :: id
    call ensure_plugins()
    if (n_plugins > 0) then
      id = trim(plugins(1)%id)
    else
      id = ""
    end if
  end function plugin_default_id

  logical function plugin_exists(id)
    character(*), intent(in) :: id
    call ensure_plugins()
    plugin_exists = find_plugin(id) > 0
  end function plugin_exists

  !> Does plugin `id` declare capability `cap` (e.g. "speaks")?
  logical function plugin_capability(id, cap)
    character(*), intent(in) :: id, cap
    integer :: p
    call ensure_plugins()
    plugin_capability = .false.
    p = find_plugin(id)
    if (p == 0) return
    plugin_capability = list_has(plugins(p)%caps, cap)
  end function plugin_capability

  !> Is `verb` in ANY registered plugin's action verb set?  (The
  !! union query that replaces the core ANIM_KINDS_EXT table.)
  logical function plugin_is_verb(verb)
    character(*), intent(in) :: verb
    integer :: p
    call ensure_plugins()
    plugin_is_verb = .false.
    do p = 1, n_plugins
      if (list_has(plugins(p)%verbs, verb)) then
        plugin_is_verb = .true.
        return
      end if
    end do
  end function plugin_is_verb

  !> The channel `verb` animates under plugin `id`; found=.false.
  !! when the plugin does not own the verb.
  subroutine plugin_verb_channel(id, verb, channel, found)
    character(*), intent(in) :: id, verb
    character(:), allocatable, intent(out) :: channel
    logical, intent(out) :: found
    integer :: p, k
    call ensure_plugins()
    channel = ""
    found = .false.
    p = find_plugin(id)
    if (p == 0) return
    do k = 1, char_list_len(plugins(p)%verbs)
      if (char_list_at(plugins(p)%verbs, k) == verb) then
        channel = char_list_at(plugins(p)%verb_channels, k)
        found = .true.
        return
      end if
    end do
  end subroutine plugin_verb_channel

  !> How many rig channels plugin `id` publishes (0 when the
  !! plugin is unknown or publishes none, e.g. the humanoid
  !! skeleton).
  integer function plugin_rig_channel_count(id)
    character(*), intent(in) :: id
    integer :: p
    call ensure_plugins()
    plugin_rig_channel_count = 0
    p = find_plugin(id)
    if (p == 0) return
    plugin_rig_channel_count = &
      char_list_len(plugins(p)%rig_channels)
  end function plugin_rig_channel_count

  !> The IDX-th (1-based) published rig channel of plugin `id`:
  !! NAME and its value FORM ("deg" | "value"); found=.false.
  !! when out of range / unknown plugin.
  subroutine plugin_rig_channel_at(id, idx, name, form, found)
    character(*), intent(in) :: id
    integer, intent(in) :: idx
    character(:), allocatable, intent(out) :: name, form
    logical, intent(out) :: found
    integer :: p
    call ensure_plugins()
    name = ""
    form = ""
    found = .false.
    p = find_plugin(id)
    if (p == 0) return
    if (idx < 1 .or. &
        idx > char_list_len(plugins(p)%rig_channels)) return
    name = char_list_at(plugins(p)%rig_channels, idx)
    form = char_list_at(plugins(p)%rig_ch_forms, idx)
    found = .true.
  end subroutine plugin_rig_channel_at

  !> The value form of one published rig channel of plugin
  !! `id`; found=.false. when the plugin does not publish it.
  subroutine plugin_rig_channel_form(id, channel, form, found)
    character(*), intent(in) :: id, channel
    character(:), allocatable, intent(out) :: form
    logical, intent(out) :: found
    integer :: p, k
    call ensure_plugins()
    form = ""
    found = .false.
    p = find_plugin(id)
    if (p == 0) return
    do k = 1, char_list_len(plugins(p)%rig_channels)
      if (char_list_at(plugins(p)%rig_channels, k) == channel) &
        then
        form = char_list_at(plugins(p)%rig_ch_forms, k)
        found = .true.
        return
      end if
    end do
  end subroutine plugin_rig_channel_form

  !> The resolver template id (TPL_*) for `verb` under plugin
  !! `id`; TPL_NONE when the verb is unknown to the plugin or
  !! has no template (its actions stay unresolved).
  integer function plugin_template_id(id, verb)
    character(*), intent(in) :: id, verb
    integer :: p, k
    call ensure_plugins()
    plugin_template_id = TPL_NONE
    p = find_plugin(id)
    if (p == 0) return
    do k = 1, char_list_len(plugins(p)%verbs)
      if (char_list_at(plugins(p)%verbs, k) == verb) then
        plugin_template_id = &
          int(int_list_at(plugins(p)%verb_templates, k))
        return
      end if
    end do
  end function plugin_template_id

  !> The plugin-owned rig description declared by plugin `id`
  !! (Timeline IR Character "rig"); found=.false. when the plugin
  !! is unknown or declares no rig.
  subroutine plugin_rig(id, rig, found)
    character(*), intent(in) :: id
    type(dyn), intent(out) :: rig
    logical, intent(out) :: found
    integer :: p
    call ensure_plugins()
    rig = dyn_null()
    found = .false.
    p = find_plugin(id)
    if (p == 0) return
    if (plugins(p)%rig%kind == DYN_K_NULL) return
    call dyn_assign(rig, dyn_copy(plugins(p)%rig))
    found = .true.
  end subroutine plugin_rig

  !> The channel of the plugin that owns `verb` (first registered
  !! owner wins); "" when no plugin owns it.
  function plugin_channel_for_verb(verb) result(channel)
    character(*), intent(in) :: verb
    character(:), allocatable :: channel
    integer :: p
    logical :: found
    call ensure_plugins()
    channel = ""
    do p = 1, n_plugins
      call plugin_verb_channel(trim(plugins(p)%id), verb, &
                               channel, found)
      if (found) return
    end do
    channel = ""
  end function plugin_channel_for_verb

  !> Schema lookup by the SURFACE word that introduces a prop in a
  !! character line (a flag's own word, else the prop name).
  subroutine plugin_prop_by_surface(id, surface, name, kind, &
                                    multi, lower, found)
    character(*), intent(in) :: id, surface
    character(:), allocatable, intent(out) :: name, kind
    logical, intent(out) :: multi, lower, found
    integer :: p, i
    call ensure_plugins()
    name = ""
    kind = ""
    multi = .false.
    lower = .true.
    found = .false.
    p = find_plugin(id)
    if (p == 0) return
    do i = 1, plugins(p)%nprops
      if (trim(plugins(p)%props(i)%surface) == surface) then
        name = trim(plugins(p)%props(i)%name)
        kind = trim(plugins(p)%props(i)%kind)
        multi = plugins(p)%props(i)%multi
        lower = plugins(p)%props(i)%lower
        found = .true.
        return
      end if
    end do
  end subroutine plugin_prop_by_surface

  !> Schema lookup by prop NAME (the props-bag key).
  subroutine plugin_prop_by_name(id, name, kind, found)
    character(*), intent(in) :: id, name
    character(:), allocatable, intent(out) :: kind
    logical, intent(out) :: found
    integer :: p, i
    call ensure_plugins()
    kind = ""
    found = .false.
    p = find_plugin(id)
    if (p == 0) return
    do i = 1, plugins(p)%nprops
      if (trim(plugins(p)%props(i)%name) == name) then
        kind = trim(plugins(p)%props(i)%kind)
        found = .true.
        return
      end if
    end do
  end subroutine plugin_prop_by_name

  !> Is `value` a legal value for prop `name` of plugin `id`?
  !! Only the closed kinds constrain the value: "enum" checks the
  !! allowed list, "flag" checks the flag surface words declared
  !! for that prop name.  Open kinds accept any value of their
  !! shape (the shape itself is checked by the caller).
  logical function plugin_prop_value_ok(id, name, value)
    character(*), intent(in) :: id, name, value
    integer :: p, i, a, b
    character(:), allocatable :: allowed, item
    call ensure_plugins()
    plugin_prop_value_ok = .false.
    p = find_plugin(id)
    if (p == 0) return
    do i = 1, plugins(p)%nprops
      if (trim(plugins(p)%props(i)%name) /= name) cycle
      select case (trim(plugins(p)%props(i)%kind))
      case ("enum")
        allowed = trim(plugins(p)%props(i)%allowed)
        a = 1
        do while (a <= len(allowed))
          b = index(allowed(a:), ",")
          if (b == 0) then
            item = allowed(a:)
            a = len(allowed) + 1
          else
            item = allowed(a:a + b - 2)
            a = a + b
          end if
          if (item == value) then
            plugin_prop_value_ok = .true.
            return
          end if
        end do
        return  ! an enum prop with no match: not ok
      case ("flag")
        if (trim(plugins(p)%props(i)%surface) == value) then
          plugin_prop_value_ok = .true.
          return
        end if
      case default
        plugin_prop_value_ok = .true.
        return
      end select
    end do
  end function plugin_prop_value_ok

  !> The allowed values of prop `name` (plugin `id`) as a
  !! ", "-joined string, for diagnostics; for a "flag" prop the
  !! flag surface words; "" when the prop is open or unknown.
  function plugin_prop_allowed_csv(id, name) result(csv)
    character(*), intent(in) :: id, name
    character(:), allocatable :: csv
    type(str_builder) :: sb
    integer :: p, i
    call ensure_plugins()
    csv = ""
    p = find_plugin(id)
    if (p == 0) return
    call sb_init(sb)
    do i = 1, plugins(p)%nprops
      if (trim(plugins(p)%props(i)%name) /= name) cycle
      select case (trim(plugins(p)%props(i)%kind))
      case ("enum")
        csv = csv_join_commas(trim(plugins(p)%props(i)%allowed))
        return
      case ("flag")
        if (sb_len(sb) > 0) call sb_add(sb, ", ")
        call sb_add(sb, trim(plugins(p)%props(i)%surface))
      end select
    end do
    csv = sb_text(sb)
  end function plugin_prop_allowed_csv

  !> All prop names of plugin `id`, ", "-joined, in schema order
  !! (duplicates collapsed), for diagnostics.
  function plugin_prop_names_csv(id) result(csv)
    character(*), intent(in) :: id
    character(:), allocatable :: csv, nm
    type(str_builder) :: sb
    integer :: p, i, j
    logical :: seen
    call ensure_plugins()
    csv = ""
    p = find_plugin(id)
    if (p == 0) return
    call sb_init(sb)
    do i = 1, plugins(p)%nprops
      nm = trim(plugins(p)%props(i)%name)
      seen = .false.
      do j = 1, i - 1
        if (trim(plugins(p)%props(j)%name) == nm) seen = .true.
      end do
      if (seen) cycle
      if (sb_len(sb) > 0) call sb_add(sb, ", ")
      call sb_add(sb, nm)
    end do
    csv = sb_text(sb)
  end function plugin_prop_names_csv

  function csv_join_commas(s) result(out)
    character(*), intent(in) :: s
    character(:), allocatable :: out
    integer :: i
    out = s
    do i = 1, len(out)
      if (out(i:i) == ",") out(i:i) = " "
    end do
    ! "a b c" -> "a, b, c": rebuild with separators.
    block
      character(:), allocatable :: item
      type(str_builder) :: sb
      integer :: a, b
      call sb_init(sb)
      a = 1
      do while (a <= len(out))
        b = index(out(a:), " ")
        if (b == 0) then
          item = out(a:)
          a = len(out) + 1
        else
          item = out(a:a + b - 2)
          a = a + b
        end if
        if (sb_len(sb) > 0) call sb_add(sb, ", ")
        call sb_add(sb, item)
      end do
      out = sb_text(sb)
    end block
  end function csv_join_commas

  ! ---------------------------------------------------------------
  ! Easing canonicalisation (flag 6 / ANIM-PLAN SS3.4).
  ! ---------------------------------------------------------------

  !> The ONE canonical spelling of an easing name.  Canonical set:
  !! linear, smooth, in, out, cubic-in, cubic-out, cubic-in-out,
  !! bezier(...), hold.  Aliases: ease-in -> cubic-in, ease-out ->
  !! cubic-out, ease-in-out -> cubic-in-out; the sentence adverbs
  !! slowly -> out, gently -> cubic-in-out (the same curves f3dc
  !! fmt canonicalises the adverbs to).  Any other name -- a
  !! canonical spelling, a bezier(...) form, or an unknown name --
  !! passes through unchanged.
  function ease_canonical(name) result(canon)
    character(*), intent(in) :: name
    character(:), allocatable :: canon
    character(:), allocatable :: n
    n = to_lower(trim(name))
    select case (n)
    case ("ease-in")
      canon = "cubic-in"
    case ("ease-out")
      canon = "cubic-out"
    case ("ease-in-out")
      canon = "cubic-in-out"
    case ("slowly")
      canon = "out"
    case ("gently")
      canon = "cubic-in-out"
    case default
      canon = n
    end select
  end function ease_canonical

end module f3dc_plugins
