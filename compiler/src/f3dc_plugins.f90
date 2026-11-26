! f3dc_plugins.f90 -- Forge3D plugin loader + registry.
!
! The all-rounder scope correction (docs/ANIM-WAVES.md, user ruling
! 2026-11-26): Forge3D is NOT a single-character-type compiler.
! The core language / compiler / Timeline IR stay rig- and
! character-type agnostic; character rigs, action verb sets,
! character prop schemas and feature capabilities are declared by
! PLUGINS.  Since Wave 5 (docs/PLUGINS.md, ADR-PLUGIN-1) a plugin
! is an EXTERNAL PACKAGE on disk -- a directory <id>/ holding one
! plugin.json manifest+declarations file -- loaded by this module
! at run time.  No plugin's data (no verb, channel, prop,
! expression name, rig record or template body) lives in core
! source; this module holds only the loader and the registry
! MECHANISM, plus the query surface the rest of the compiler has
! always used (parser, desugar, validator, resolver, emitter call
! the same procedures with the same signatures; only where the
! answers come from changed: a package file, not a registration
! block compiled into the binary).
!
! Loader semantics (docs/PLUGINS.md SS4):
!   * plugin_configure(root) is called once by the CLI with the
!     driver_repo_root; the first registry query then loads.
!   * Search list: if the environment variable F3DC_PLUGIN_PATH
!     is SET (whatever its value), its colon-separated entries
!     are the whole list -- the empty string loads nothing.  If
!     it is UNSET, the list is [<repo_root>/plugins, ./plugins]
!     (or just ./plugins when no root was configured, e.g. a
!     caller that linked the modules directly).
!   * Within each search directory, package directories are
!     enumerated in lexicographic order; a package registers
!     whole or not at all.  The first package with a given id
!     wins; a later duplicate is skipped with a W205 warning.
!     A malformed package (missing/unreadable/invalid plugin.json,
!     format /= 1, manifest id /= directory name, a required key
!     of the wrong type, a verb naming a missing template, a
!     registry limit exceeded) is skipped with one W205 warning
!     naming the package directory and the reason.  The loader
!     NEVER stops the process and never crashes on bad package
!     data: a skipped package simply does not exist as far as the
!     registry is concerned (a film that then needs it is the
!     validator's E214, docs/PLUGINS.md SS5).
!   * Warnings are collected here; the CLI drains them once via
!     plugin_take_warnings() and prints them as W205 diagnostics.
!
! A plugin declares:
!   * id            -- its stable identifier (== directory name).
!   * version       -- its own version string (opaque to core).
!   * channels      -- the generic channel ids its verbs animate.
!   * verbs         -- its action verb set; every spelling (form)
!                      maps to the channel that verb animates and
!                      to a template name (or none: the verb's
!                      actions stay unresolved).
!   * templates     -- template bodies by name, carried as dyn
!                      data for the resolver's generic template
!                      interpreter (plugin_template query).
!   * rig           -- the plugin-owned rig description, carried
!                      opaquely into the Timeline IR Character
!                      "rig" payload (plugin_rig returns the
!                      package's rig sub-tree verbatim).
!   * rig_channels  -- the published per-channel key vocabulary a
!                      resolved action track may carry, each with
!                      its value form ("deg" | "value").
!   * expression_codes -- expression name -> numeric code map.
!   * prop schema   -- character prop name -> kind, so character
!                      prop parsing/validation is data-driven:
!                      kind is one of
!                        "flag"       a bare word (its surface word
!                                     IS the value; several flag
!                                     entries may share one prop
!                                     name -- the alternatives of
!                                     one prop)
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
!                      instead of hardcoding rules (e.g. a plugin
!                      may declare that its characters may speak
!                      dialogue, ANIM-PLAN SS2.4 E211).
!
! ease_canonical() also lives here: the single spelling authority
! for easing names (Wave-2 must-fix flag 6, ANIM-PLAN SS3.4).  The
! canonical set is: linear, smooth, in, out, cubic-in, cubic-out,
! cubic-in-out, bezier(...), hold.  The alias spellings ease-in /
! ease-out / ease-in-out and the sentence adverbs slowly / gently
! map onto it; every other name passes through unchanged.
module f3dc_plugins
  use f3dc_str, only: char_list, char_list_append, char_list_len, &
       char_list_at, char_list_clear, to_lower, str_builder, &
       sb_init, sb_add, &
       sb_text, sb_len, int_list, int_list_append, int_list_len, &
       int_list_at, int_list_clear, fmt_int
  use, intrinsic :: iso_fortran_env, only: int64, real64
  use f3dc_dyn, only: dyn, dyn_null, dyn_copy, dyn_assign, &
       dyn_free, &
       dyn_dict_get, dyn_dict_has, dyn_dict_len, dyn_dict_key_at, &
       dyn_list_len, dyn_list_at, &
       DYN_K_NULL, DYN_K_BOOL, DYN_K_INT, DYN_K_REAL, DYN_K_STR, &
       DYN_K_LIST, DYN_K_DICT
  use f3dc_ir, only: ir_json_parse
  use f3dc_driver, only: driver_run_capture, driver_quote, &
       driver_is_dir, driver_file_exists
  implicit none
  private

  public :: plugin_configure
  public :: plugin_take_warnings
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
  public :: plugin_template
  public :: plugin_expression_code
  public :: ease_canonical

  ! COORDINATOR AMENDMENT (Wave 5, slice I2) to docs/PLUGINS.md:
  ! the language's default character plugin id remains a
  ! language-level constant -- it is language spec (the id a
  ! character belongs to when neither the scene nor the registry
  ! default resolution says otherwise), not plugin data.  This
  ! named constant is the ONE place core source names it; every
  ! other plugin datum comes from package files.
  character(len=*), parameter, public :: DEFAULT_PLUGIN_ID = &
       "stickman"

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
    character(64) :: id = ""
    character(64) :: version = ""
    character(1024) :: origin = ""  ! package dir it loaded from
    type(dyn) :: rig  ! plugin-owned rig description (Timeline IR
                      ! Character "rig" payload), the package's
                      ! "rig" sub-tree verbatim; null when the
                      ! plugin declares none.
    type(dyn) :: templates  ! the package's "templates" object
                            ! (template name -> template body dyn),
                            ! or null when it declares none.
    type(char_list) :: channels
    type(char_list) :: verbs
    type(char_list) :: verb_channels  ! parallel to verbs
    type(char_list) :: verb_templates ! parallel to verbs: template
                                      ! name, "" = no template
    type(char_list) :: rig_channels   ! published rig channels
    type(char_list) :: rig_ch_forms   ! parallel: "deg" | "value"
    type(char_list) :: caps
    type(char_list) :: expr_names     ! expression_codes keys
    type(int_list) :: expr_codes      ! parallel: numeric codes
    type(prop_rec) :: props(MAX_PROPS)
    integer :: nprops = 0
  end type plugin_rec

  type(plugin_rec) :: plugins(MAX_PLUGINS)
  integer :: n_plugins = 0
  logical :: plugins_ready = .false.

  ! Loader configuration / warning collection (module state).
  logical :: configured = .false.
  character(:), allocatable :: configured_root
  type(char_list) :: load_warnings
  integer :: warnings_drained = 0

contains

  ! ---------------------------------------------------------------
  ! Loader configuration + warning drain.
  ! ---------------------------------------------------------------

  !> Record the repo root the loader anchors its default search
  !! list on.  Called once by the CLI at program entry (with the
  !! driver_repo_root); idempotent, and a no-op once loading has
  !! happened.  Loading itself stays lazy (ensure_plugins).
  subroutine plugin_configure(root)
    character(*), intent(in) :: root
    if (configured .or. plugins_ready) return
    configured = .true.
    configured_root = root
  end subroutine plugin_configure

  !> Drain the loader warnings collected so far: MSGS receives
  !! every warning not returned by an earlier drain (message texts
  !! only; the CLI wraps them as W205 diagnostics).  Draining
  !! forces the one-time load, so the CLI can drain at entry,
  !! before any command output.
  subroutine plugin_take_warnings(msgs)
    type(char_list), intent(out) :: msgs
    integer :: k
    call ensure_plugins()
    do k = warnings_drained + 1, char_list_len(load_warnings)
      call char_list_append(msgs, char_list_at(load_warnings, k))
    end do
    warnings_drained = char_list_len(load_warnings)
  end subroutine plugin_take_warnings

  subroutine add_warning(msg)
    character(*), intent(in) :: msg
    call char_list_append(load_warnings, msg)
  end subroutine add_warning

  ! ---------------------------------------------------------------
  ! The loader.  Load-once: the first registry query (or warning
  ! drain) triggers it when configuration happened; with no
  ! configuration the F3DC_PLUGIN_PATH-or-./plugins fallback list
  ! applies (docs/PLUGINS.md SS4).
  ! ---------------------------------------------------------------
  subroutine ensure_plugins()
    type(char_list) :: dirs
    character(:), allocatable :: env
    integer :: st, ln, i, a
    if (plugins_ready) return
    plugins_ready = .true.
    call get_environment_variable("F3DC_PLUGIN_PATH", length=ln, &
                                  status=st)
    if (st == 0) then
      ! Set (whatever its value): the value IS the whole list;
      ! the empty string means an empty list -- load nothing.
      if (ln > 0) then
        allocate (character(len=ln) :: env)
        call get_environment_variable("F3DC_PLUGIN_PATH", env, &
                                      status=st)
        a = 1
        do i = 1, ln + 1
          if (i > ln .or. env(i:i) == ":") then
            if (i > a) call char_list_append(dirs, env(a:i - 1))
            a = i + 1
          end if
        end do
      end if
    else
      if (configured) &
        call char_list_append(dirs, &
                              trim(configured_root)//"/plugins")
      call char_list_append(dirs, "./plugins")
    end if
    ! Dedupe by canonical key: when the CWD is the repo root,
    ! "./plugins" IS "<root>/plugins", and enumerating it twice
    ! would re-load every package and report each as a spurious
    ! duplicate (W205).  The same applies to repeated entries in
    ! F3DC_PLUGIN_PATH.  Keys are string-canonical (see canon_key)
    ! -- deliberately NOT a realpath subprocess per directory:
    ! the loader runs on every f3dc invocation and must stay
    ! cheap.
    block
      type(char_list) :: seen
      character(:), allocatable :: d, key, cwd, out, err
      integer :: k, rc
      logical :: dup, timed_out
      call driver_run_capture("pwd", "", 0, rc, out, err, &
                              timed_out)
      if (rc == 0 .and. len_trim(out) > 0) then
        cwd = trim(out)
        if (cwd(len(cwd):len(cwd)) == achar(10)) &
          cwd = cwd(1:len(cwd) - 1)
      else
        cwd = ""
      end if
      do i = 1, char_list_len(dirs)
        d = char_list_at(dirs, i)
        key = canon_key(d, cwd)
        dup = .false.
        do k = 1, char_list_len(seen)
          if (char_list_at(seen, k) == key) dup = .true.
        end do
        if (dup) cycle
        call char_list_append(seen, key)
        call load_search_dir(d)
      end do
    end block
  end subroutine ensure_plugins

  !> Canonical key of a search directory for dedupe: absolute
  !! paths key as themselves (trailing slash stripped); relative
  !! paths key as <cwd>/<path> with a leading "./" removed.  Two
  !! spellings of the same directory through "." segments agree;
  !! ".." segments are not folded (a search list repeating a
  !! directory via ".." re-enumerates it -- harmless: package
  !! loads are idempotent and duplicate ids from DIFFERENT
  !! directories still warn as designed).
  function canon_key(dir, cwd) result(key)
    character(*), intent(in) :: dir, cwd
    character(:), allocatable :: key, d
    d = dir
    if (len(d) > 1) then
      if (d(len(d):len(d)) == "/") d = d(1:len(d) - 1)
    end if
    if (len(d) >= 1 .and. d(1:1) == "/") then
      key = d
    else
      if (len(d) >= 2) then
        if (d(1:2) == "./") d = d(3:)
      end if
      if (len(cwd) > 0) then
        key = cwd//"/"//d
      else
        key = d
      end if
    end if
  end function canon_key

  !> Enumerate the package directories of one search directory in
  !! lexicographic order and load each.  A nonexistent or
  !! non-directory entry is skipped silently (search-path
  !! tolerance, like PATH).
  subroutine load_search_dir(dir)
    character(*), intent(in) :: dir
    character(len=256) :: names(4096)
    character(len=256) :: tmp
    character(:), allocatable :: out, err, line
    integer :: rc, n, i, j, pos, start
    logical :: timed_out
    n = 0
    call driver_run_capture("ls -1 "//driver_quote(dir), "", 0, &
                            rc, out, err, timed_out)
    if (rc /= 0) return
    ! Split the listing into lines.
    start = 1
    do pos = 1, len(out) + 1
      if (pos > len(out) .or. out(pos:pos) == achar(10)) then
        if (pos > start .and. n < 4096) then
          line = out(start:pos - 1)
          if (len(line) > 0) then
            if (line(len(line):len(line)) == achar(13)) &
              line = line(1:len(line) - 1)
          end if
          if (len(line) > 0) then
            n = n + 1
            names(n) = line
          end if
        end if
        start = pos + 1
      end if
    end do
    ! Lexicographic order by directory name (insertion sort; the
    ! listing is usually sorted already, so this is near-free and
    ! makes the order locale-independent).
    do i = 2, n
      tmp = names(i)
      j = i - 1
      do while (j >= 1)
        if (.not. (names(j) > tmp)) exit
        names(j + 1) = names(j)
        j = j - 1
      end do
      names(j + 1) = tmp
    end do
    do i = 1, n
      if (driver_is_dir(dir//"/"//trim(names(i)))) &
        call load_package(dir//"/"//trim(names(i)), &
                          trim(names(i)))
    end do
  end subroutine load_search_dir

  !> Read a whole file as text (stream read); OK=.false. when the
  !! file cannot be opened or read.
  subroutine read_text_file(path, text, ok)
    character(*), intent(in) :: path
    character(:), allocatable, intent(out) :: text
    logical, intent(out) :: ok
    integer :: unit, ios, sz
    logical :: there
    ok = .false.
    inquire (file=path, exist=there, size=sz)
    if (.not. there) then
      text = ""
      return
    end if
    open (newunit=unit, file=path, access="stream", &
          form="unformatted", status="old", iostat=ios)
    if (ios /= 0) then
      text = ""
      return
    end if
    allocate (character(len=max(sz, 0)) :: text)
    if (sz > 0) read (unit, iostat=ios) text
    close (unit)
    ok = (ios == 0)
  end subroutine read_text_file

  !> Load one package directory into the registry.  Any defect
  !! skips the WHOLE package with one W205 warning (collected, not
  !! printed here); this subroutine never stops the process.
  !> Reset a plugin slot to its just-declared state, field by
  !! field.  (Not `plugins(p) = plugin_rec()`: flang-18 rejects
  !! the empty structure constructor for a type with allocatable
  !! components -- dyn and the growable lists -- even though
  !! every scalar component carries a default.  gfortran accepts
  !! both; this form is the portable one.)
  subroutine reset_plugin_rec(r)
    type(plugin_rec), intent(inout) :: r
    integer :: i
    r%id = ""
    r%version = ""
    r%origin = ""
    call dyn_free(r%rig)
    call dyn_free(r%templates)
    call char_list_clear(r%channels)
    call char_list_clear(r%verbs)
    call char_list_clear(r%verb_channels)
    call char_list_clear(r%verb_templates)
    call char_list_clear(r%rig_channels)
    call char_list_clear(r%rig_ch_forms)
    call char_list_clear(r%caps)
    call char_list_clear(r%expr_names)
    call int_list_clear(r%expr_codes)
    do i = 1, MAX_PROPS
      r%props(i)%name = ""
      r%props(i)%kind = ""
      r%props(i)%surface = ""
      r%props(i)%allowed = ""
      r%props(i)%multi = .false.
      r%props(i)%lower = .true.
    end do
    r%nprops = 0
  end subroutine reset_plugin_rec

  subroutine load_package(pkgdir, dirname)
    character(*), intent(in) :: pkgdir, dirname
    type(dyn) :: root, v, item, sub
    character(:), allocatable :: text, idstr, tname, reason
    logical :: ok, bad
    integer :: p, i, dup
    bad = .false.
    reason = ""
    if (.not. driver_file_exists(pkgdir//"/plugin.json")) then
      call add_warning("plugin package '"//pkgdir// &
                       "' skipped: plugin.json is missing")
      return
    end if
    call read_text_file(pkgdir//"/plugin.json", text, ok)
    if (.not. ok) then
      call add_warning("plugin package '"//pkgdir// &
                       "' skipped: plugin.json is unreadable")
      return
    end if
    call ir_json_parse(text, root, ok)
    if (.not. ok) then
      call add_warning("plugin package '"//pkgdir// &
                       "' skipped: plugin.json is not valid JSON")
      return
    end if
    if (root%kind /= DYN_K_DICT) then
      call add_warning("plugin package '"//pkgdir//"' skipped: "// &
                       "plugin.json top level is not an object")
      return
    end if
    ! format: exactly 1 loads; another integral value is the
    ! documented unsupported-format warning; anything else is a
    ! malformed manifest.
    v = dyn_dict_get(root, "format")
    select case (v%kind)
    case (DYN_K_INT)
      if (v%i /= 1) then
        call add_warning("plugin package '"//pkgdir//"' skipped: "// &
                         "package format "// &
                         trim(fmt_int(v%i))// &
                         " is not supported by this compiler")
        return
      end if
    case (DYN_K_REAL)
      if (v%r == 1.0_real64) then
        continue
      else if (v%r == aint(v%r)) then
        call add_warning("plugin package '"//pkgdir//"' skipped: "// &
                         "package format "// &
                         trim(fmt_int(int(v%r, int64)))// &
                         " is not supported by this compiler")
        return
      else
        bad = .true.
        reason = "manifest key 'format' is missing or has the "// &
                 "wrong type"
      end if
    case default
      bad = .true.
      reason = "manifest key 'format' is missing or has the "// &
               "wrong type"
    end select
    if (bad) then
      call add_warning("plugin package '"//pkgdir//"' skipped: "// &
                       reason)
      return
    end if
    ! id: a string equal to the directory name.
    v = dyn_dict_get(root, "id")
    if (v%kind /= DYN_K_STR) then
      call add_warning("plugin package '"//pkgdir//"' skipped: "// &
                       "manifest key 'id' is missing or has the "// &
                       "wrong type")
      return
    end if
    idstr = v%s
    if (idstr /= dirname) then
      call add_warning("plugin package '"//pkgdir//"' skipped: "// &
                       "manifest id '"//idstr// &
                       "' does not match directory name '"// &
                       dirname//"'")
      return
    end if
    dup = find_plugin(idstr)
    if (dup > 0) then
      call add_warning("plugin '"//idstr//"' in '"//pkgdir// &
                       "' skipped: already loaded from '"// &
                       trim(plugins(dup)%origin)//"'")
      return
    end if
    if (n_plugins >= MAX_PLUGINS) then
      call add_warning("plugin package '"//pkgdir//"' skipped: "// &
                       "registry limit of "// &
                       trim(fmt_int(int(MAX_PLUGINS, int64)))// &
                       " plugins reached")
      return
    end if
    ! Build into the next slot; n_plugins only advances on full
    ! success, so a failed package leaves no partial registration.
    p = n_plugins + 1
    call reset_plugin_rec(plugins(p))
    plugins(p)%id = idstr
    plugins(p)%origin = pkgdir
    ! version: opaque metadata, recorded never compared.
    v = dyn_dict_get(root, "version")
    if (v%kind == DYN_K_STR) plugins(p)%version = v%s
    ! rig: carried opaquely, verbatim (object or null).
    if (dyn_dict_has(root, "rig")) then
      v = dyn_dict_get(root, "rig")
      if (v%kind /= DYN_K_DICT .and. v%kind /= DYN_K_NULL) then
        call malformed(pkgdir, &
                       "manifest key 'rig' has the wrong type")
        return
      end if
      call dyn_assign(plugins(p)%rig, dyn_copy(v))
    end if
    ! templates: object of template bodies, stored verbatim for
    ! the resolver's interpreter; may be absent (no templates).
    if (dyn_dict_has(root, "templates")) then
      v = dyn_dict_get(root, "templates")
      if (v%kind /= DYN_K_DICT) then
        call malformed(pkgdir, &
                       "manifest key 'templates' has the wrong type")
        return
      end if
      call dyn_assign(plugins(p)%templates, dyn_copy(v))
    end if
    ! capabilities + channels: string lists.
    call load_str_list(root, "capabilities", plugins(p)%caps, &
                       bad, reason)
    if (bad) then
      call malformed(pkgdir, reason)
      return
    end if
    call load_str_list(root, "channels", plugins(p)%channels, &
                       bad, reason)
    if (bad) then
      call malformed(pkgdir, reason)
      return
    end if
    ! rig_channels: [{"name","form"}], form in {"deg","value"}.
    v = dyn_dict_get(root, "rig_channels")
    if (v%kind /= DYN_K_LIST) then
      call malformed(pkgdir, "manifest key 'rig_channels' is "// &
                     "missing or has the wrong type")
      return
    end if
    do i = 1, dyn_list_len(v)
      item = dyn_list_at(v, i)
      if (item%kind /= DYN_K_DICT) then
        call malformed(pkgdir, "rig channel record "// &
                       trim(fmt_int(int(i, int64)))//" is malformed")
        return
      end if
      sub = dyn_dict_get(item, "name")
      if (sub%kind /= DYN_K_STR) then
        call malformed(pkgdir, "rig channel record "// &
                       trim(fmt_int(int(i, int64)))//" is malformed")
        return
      end if
      tname = sub%s
      sub = dyn_dict_get(item, "form")
      if (sub%kind /= DYN_K_STR) then
        call malformed(pkgdir, "rig channel record "// &
                       trim(fmt_int(int(i, int64)))//" is malformed")
        return
      end if
      if (sub%s /= "deg" .and. sub%s /= "value") then
        call malformed(pkgdir, "rig channel record "// &
                       trim(fmt_int(int(i, int64)))//" is malformed")
        return
      end if
      call char_list_append(plugins(p)%rig_channels, tname)
      call char_list_append(plugins(p)%rig_ch_forms, sub%s)
    end do
    ! expression_codes: {name: number} (optional key).
    if (dyn_dict_has(root, "expression_codes")) then
      v = dyn_dict_get(root, "expression_codes")
      if (v%kind /= DYN_K_DICT) then
        call malformed(pkgdir, "manifest key 'expression_codes' "// &
                       "has the wrong type")
        return
      end if
      call load_expr_codes(p, v, bad, reason)
      if (bad) then
        call malformed(pkgdir, reason)
        return
      end if
    end if
    ! props: array of prop records, in declaration order.
    v = dyn_dict_get(root, "props")
    if (v%kind /= DYN_K_LIST) then
      call malformed(pkgdir, "manifest key 'props' is missing "// &
                     "or has the wrong type")
      return
    end if
    do i = 1, dyn_list_len(v)
      item = dyn_list_at(v, i)
      call load_prop(p, item, i, bad, reason)
      if (bad) then
        call malformed(pkgdir, reason)
        return
      end if
    end do
    ! verbs: array of {"forms":[...], "channel", "template"}.
    v = dyn_dict_get(root, "verbs")
    if (v%kind /= DYN_K_LIST) then
      call malformed(pkgdir, "manifest key 'verbs' is missing "// &
                     "or has the wrong type")
      return
    end if
    do i = 1, dyn_list_len(v)
      item = dyn_list_at(v, i)
      call load_verb(p, item, i, bad, reason)
      if (bad) then
        call malformed(pkgdir, reason)
        return
      end if
    end do
    n_plugins = p
  end subroutine load_package

  !> Emit the malformed-package W205 for PKGDIR with REASON.
  subroutine malformed(pkgdir, reason)
    character(*), intent(in) :: pkgdir, reason
    call add_warning("plugin package '"//pkgdir//"' skipped: "// &
                     reason)
  end subroutine malformed

  !> Load a required string-list key into LIST.
  subroutine load_str_list(root, key, list, bad, reason)
    type(dyn), intent(in) :: root
    character(*), intent(in) :: key
    type(char_list), intent(inout) :: list
    logical, intent(out) :: bad
    character(:), allocatable, intent(out) :: reason
    type(dyn) :: v, item
    integer :: i
    bad = .false.
    reason = ""
    v = dyn_dict_get(root, key)
    if (v%kind /= DYN_K_LIST) then
      bad = .true.
      reason = "manifest key '"//key//"' is missing or has the "// &
               "wrong type"
      return
    end if
    do i = 1, dyn_list_len(v)
      item = dyn_list_at(v, i)
      if (item%kind /= DYN_K_STR) then
        bad = .true.
        reason = "manifest key '"//key//"' is missing or has "// &
                 "the wrong type"
        return
      end if
      call char_list_append(list, item%s)
    end do
  end subroutine load_str_list

  !> Load the expression_codes object of slot P.
  subroutine load_expr_codes(p, v, bad, reason)
    integer, intent(in) :: p
    type(dyn), intent(in) :: v
    logical, intent(out) :: bad
    character(:), allocatable, intent(out) :: reason
    type(dyn) :: val
    character(:), allocatable :: key
    integer :: i
    bad = .false.
    reason = ""
    do i = 1, dyn_dict_len(v)
      key = dyn_dict_key_at(v, i)
      val = dyn_copy(dyn_dict_get(v, key))
      select case (val%kind)
      case (DYN_K_INT)
        call char_list_append(plugins(p)%expr_names, key)
        call int_list_append(plugins(p)%expr_codes, val%i)
      case (DYN_K_REAL)
        call char_list_append(plugins(p)%expr_names, key)
        call int_list_append(plugins(p)%expr_codes, &
                             int(nint(val%r), int64))
      case default
        bad = .true.
        reason = "expression_codes entry '"//key// &
                 "' is not a number"
        return
      end select
    end do
  end subroutine load_expr_codes

  !> Load one prop record (ITEM, the IDX-th of the props array)
  !! into slot P.
  subroutine load_prop(p, item, idx, bad, reason)
    integer, intent(in) :: p, idx
    type(dyn), intent(in) :: item
    logical, intent(out) :: bad
    character(:), allocatable, intent(out) :: reason
    type(dyn) :: f, al, el
    character(:), allocatable :: allowed_csv
    integer :: i, slot
    bad = .false.
    reason = ""
    if (item%kind /= DYN_K_DICT) then
      bad = .true.
      reason = "prop record "//trim(fmt_int(int(idx, int64)))// &
               " is malformed"
      return
    end if
    if (plugins(p)%nprops >= MAX_PROPS) then
      bad = .true.
      reason = "prop schema exceeds the registry limit of "// &
               trim(fmt_int(int(MAX_PROPS, int64)))//" records"
      return
    end if
    slot = plugins(p)%nprops + 1
    f = dyn_dict_get(item, "name")
    if (f%kind /= DYN_K_STR) then
      bad = .true.
      reason = "prop record "//trim(fmt_int(int(idx, int64)))// &
               " is malformed"
      return
    end if
    plugins(p)%props(slot)%name = f%s
    f = dyn_dict_get(item, "kind")
    if (f%kind /= DYN_K_STR) then
      bad = .true.
      reason = "prop record "//trim(fmt_int(int(idx, int64)))// &
               " is malformed"
      return
    end if
    select case (f%s)
    case ("flag", "enum", "word", "free", "number", "colour", &
          "itemcolour")
      plugins(p)%props(slot)%kind = f%s
    case default
      bad = .true.
      reason = "prop record "//trim(fmt_int(int(idx, int64)))// &
               " is malformed"
      return
    end select
    f = dyn_dict_get(item, "surface")
    if (f%kind /= DYN_K_STR) then
      bad = .true.
      reason = "prop record "//trim(fmt_int(int(idx, int64)))// &
               " is malformed"
      return
    end if
    plugins(p)%props(slot)%surface = f%s
    ! allowed: array of strings -> comma-joined ("" when absent).
    allowed_csv = ""
    if (dyn_dict_has(item, "allowed")) then
      al = dyn_dict_get(item, "allowed")
      if (al%kind /= DYN_K_LIST) then
        bad = .true.
        reason = "prop record "//trim(fmt_int(int(idx, int64)))// &
                 " is malformed"
        return
      end if
      do i = 1, dyn_list_len(al)
        el = dyn_list_at(al, i)
        if (el%kind /= DYN_K_STR) then
          bad = .true.
          reason = "prop record "//trim(fmt_int(int(idx, int64)))// &
                   " is malformed"
          return
        end if
        if (i > 1) allowed_csv = allowed_csv//","
        allowed_csv = allowed_csv//el%s
      end do
    end if
    plugins(p)%props(slot)%allowed = allowed_csv
    f = dyn_dict_get(item, "multi")
    if (f%kind == DYN_K_BOOL) plugins(p)%props(slot)%multi = f%b
    f = dyn_dict_get(item, "lower")
    if (f%kind == DYN_K_BOOL) plugins(p)%props(slot)%lower = f%b
    plugins(p)%nprops = slot
  end subroutine load_prop

  !> Load one verb record (ITEM, the IDX-th of the verbs array)
  !! into slot P: every form spelling becomes one registry entry.
  subroutine load_verb(p, item, idx, bad, reason)
    integer, intent(in) :: p, idx
    type(dyn), intent(in) :: item
    logical, intent(out) :: bad
    character(:), allocatable, intent(out) :: reason
    type(dyn) :: forms, f, el
    character(:), allocatable :: channel, tname
    integer :: i
    bad = .false.
    reason = ""
    if (item%kind /= DYN_K_DICT) then
      bad = .true.
      reason = "verb record "//trim(fmt_int(int(idx, int64)))// &
               " is malformed"
      return
    end if
    forms = dyn_dict_get(item, "forms")
    if (forms%kind /= DYN_K_LIST .or. dyn_list_len(forms) == 0) &
      then
      bad = .true.
      reason = "verb record "//trim(fmt_int(int(idx, int64)))// &
               " is malformed"
      return
    end if
    f = dyn_dict_get(item, "channel")
    if (f%kind /= DYN_K_STR) then
      bad = .true.
      reason = "verb record "//trim(fmt_int(int(idx, int64)))// &
               " is malformed"
      return
    end if
    channel = f%s
    tname = ""
    if (dyn_dict_has(item, "template")) then
      f = dyn_dict_get(item, "template")
      select case (f%kind)
      case (DYN_K_NULL)
        tname = ""
      case (DYN_K_STR)
        tname = f%s
        if (plugins(p)%templates%kind /= DYN_K_DICT .or. &
            .not. dyn_dict_has(plugins(p)%templates, tname)) then
          bad = .true.
          reason = "verb record "// &
                   trim(fmt_int(int(idx, int64)))// &
                   " names unknown template '"//tname//"'"
          return
        end if
      case default
        bad = .true.
        reason = "verb record "//trim(fmt_int(int(idx, int64)))// &
                 " is malformed"
        return
      end select
    end if
    do i = 1, dyn_list_len(forms)
      el = dyn_list_at(forms, i)
      if (el%kind /= DYN_K_STR) then
        bad = .true.
        reason = "verb record "//trim(fmt_int(int(idx, int64)))// &
                 " is malformed"
        return
      end if
      call char_list_append(plugins(p)%verbs, el%s)
      call char_list_append(plugins(p)%verb_channels, channel)
      call char_list_append(plugins(p)%verb_templates, tname)
    end do
  end subroutine load_verb

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
  !! none.  Resolution: the language default plugin (see
  !! DEFAULT_PLUGIN_ID) when it is loaded; otherwise the first
  !! loaded plugin (first-loaded-wins, the registry default);
  !! with an empty registry the language default id is still
  !! returned, so the character carries the id it is missing and
  !! the validator can name it (E214, docs/PLUGINS.md SS5).
  function plugin_default_id() result(id)
    character(:), allocatable :: id
    call ensure_plugins()
    if (find_plugin(DEFAULT_PLUGIN_ID) > 0) then
      id = DEFAULT_PLUGIN_ID
    else if (n_plugins > 0) then
      id = trim(plugins(1)%id)
    else
      id = DEFAULT_PLUGIN_ID
    end if
  end function plugin_default_id

  logical function plugin_exists(id)
    character(*), intent(in) :: id
    call ensure_plugins()
    plugin_exists = find_plugin(id) > 0
  end function plugin_exists

  !> Does plugin `id` declare capability `cap`?
  logical function plugin_capability(id, cap)
    character(*), intent(in) :: id, cap
    integer :: p
    call ensure_plugins()
    plugin_capability = .false.
    p = find_plugin(id)
    if (p == 0) return
    plugin_capability = list_has(plugins(p)%caps, cap)
  end function plugin_capability

  !> Is `verb` in ANY loaded plugin's action verb set?  (The union
  !! query that replaces the core ANIM_KINDS_EXT table.)
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
  !! plugin is unknown or publishes none).
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

  !> The template body for `verb` under plugin `id`: the dyn
  !! sub-tree the package's "templates" object holds under the
  !! template name the verb record declares, copied verbatim.
  !! found=.false. (and TEMPLATE a null dyn) when the plugin is
  !! unknown, the verb is unknown to it, or the verb declares no
  !! template (its actions stay unresolved).  This replaces the
  !! old integer template-id query: template ids were never
  !! emitted and are now package data, not core constants.
  subroutine plugin_template(id, verb, template, found)
    character(*), intent(in) :: id, verb
    type(dyn), intent(out) :: template
    logical, intent(out) :: found
    integer :: p, k
    character(:), allocatable :: tname
    call ensure_plugins()
    template = dyn_null()
    found = .false.
    p = find_plugin(id)
    if (p == 0) return
    do k = 1, char_list_len(plugins(p)%verbs)
      if (char_list_at(plugins(p)%verbs, k) == verb) then
        tname = char_list_at(plugins(p)%verb_templates, k)
        if (len(tname) == 0) return
        if (plugins(p)%templates%kind /= DYN_K_DICT) return
        if (.not. dyn_dict_has(plugins(p)%templates, tname)) &
          return
        call dyn_assign(template, &
                        dyn_copy(dyn_dict_get( &
                                 plugins(p)%templates, tname)))
        found = .true.
        return
      end if
    end do
  end subroutine plugin_template

  !> The numeric code plugin `id` assigns to expression `name`
  !! (its package "expression_codes" map); found=.false. when the
  !! plugin declares no such expression (or none at all).
  subroutine plugin_expression_code(id, name, code, found)
    character(*), intent(in) :: id, name
    integer, intent(out) :: code
    logical, intent(out) :: found
    integer :: p, k
    call ensure_plugins()
    code = 0
    found = .false.
    p = find_plugin(id)
    if (p == 0) return
    do k = 1, char_list_len(plugins(p)%expr_names)
      if (char_list_at(plugins(p)%expr_names, k) == name) then
        code = int(int_list_at(plugins(p)%expr_codes, k))
        found = .true.
        return
      end if
    end do
  end subroutine plugin_expression_code

  !> The plugin-owned rig description declared by plugin `id`
  !! (Timeline IR Character "rig"): the package's "rig" sub-tree,
  !! returned verbatim; found=.false. when the plugin is unknown
  !! or declares no rig.
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

  !> The channel of the plugin that owns `verb` (first loaded
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
