! f3dc_val_common.f90 -- shared state, limits, generic
! adapters and the section registry for the Forge3D validator
! (split from f3dc_validate.f90, v3.0 Phase 6 C2).  Every
! per-family validator module uses this one module: the
! vstate closure state (vs), the helpers (verr/verrn/vfield/
! props_of/get_num/...) and the registry live here exactly
! once -- no duplication across family modules.
module f3dc_val_common
  use, intrinsic :: iso_fortran_env, only: int64, real64
  use, intrinsic :: ieee_arithmetic, only: ieee_is_finite, &
       ieee_value, ieee_quiet_nan, ieee_positive_inf
  use f3dc_dyn, only: dyn, dyn_null, dyn_bool, dyn_int, &
       dyn_real, dyn_str, dyn_list, dyn_dict, dyn_copy, &
       dyn_assign, dyn_list_push, dyn_list_len, dyn_list_at, &
       dyn_dict_get, dyn_dict_set, dyn_dict_has, dyn_dict_len, &
       dyn_dict_key_at, dyn_dict_value_at, DYN_K_NULL, &
       DYN_K_BOOL, DYN_K_INT, DYN_K_REAL, DYN_K_STR, &
       DYN_K_LIST, DYN_K_DICT
  use f3dc_errors, only: error_bag_t, span_t, make_span, &
       make_diagnostic, make_diagnostic_span, error_bag_add, &
       error_bag_has_errors, error_bag_error_count
  use f3dc_str, only: fmt_int, fmt_real, to_lower, &
       str_builder, sb_init, sb_add, sb_text
  use f3dc_ir, only: ir_parse_color
  implicit none
  private
  public :: vget
  public :: vfield
  public :: py_str
  public :: repr_str
  public :: hex2
  public :: py_repr
  public :: py_truthy
  public :: props_of
  public :: get_num
  public :: str_to_real
  public :: strip_ws
  public :: is_ws
  public :: get_int
  public :: get_vec3
  public :: vget_scalar
  public :: vget_vec3_typed
  public :: vec3_or
  public :: finite_vec
  public :: node_span
  public :: verr
  public :: verrn
  public :: verr_full
  public :: vwarn_full
  public :: program_is_film
  public :: istr
  public :: rstr
  public :: join_words
  public :: in_words
  public :: vec3_dyn
  public :: rgb_dyn
  public :: parse_color_val
  public :: classify_node
  public :: children_of
  public :: statements_of
  public :: check_dim
  public :: check_image_dim
  public :: join_path
  public :: path_is_file
  public :: path_ext_lower
  public :: set_scene_extension
  public :: vs
  public :: vstate
  public :: vctx
  public :: val_ctx
  public :: val_register
  public :: val_run_sections
  public :: val_reset_registry
  public :: MAX_DIM
  public :: MIN_IMAGE
  public :: MAX_IMAGE
  public :: MAX_OBJECTS
  public :: MAX_TRIANGLES
  public :: MIN_SEGMENTS
  public :: MAX_SEGMENTS
  public :: MIN_FPS
  public :: MAX_FPS
  public :: MAX_DURATION
  public :: MAX_SPEED
  public :: PRIMITIVES
  public :: GEOM_PRIMS
  public :: MATERIALS
  public :: ANIM_KINDS
  public :: ANIM_KINDS_EXT
  public :: LIGHT_KINDS_V1
  public :: CONTROLS_KINDS
  public :: EASES
  public :: RENDER_EXTS
  public :: EXPORT_KINDS
  public :: DEFAULT_BG
  public :: XYZ_CHARS
  public :: DEFAULT_OUTPUT
  public :: COLOR_NAMES
  public :: COLOR_RGB
  public :: C_UNKNOWN
  public :: C_SCENE
  public :: C_CAMERA
  public :: C_LIGHT
  public :: C_CONTROLS
  public :: C_LOAD
  public :: C_ANIM
  public :: C_OUTPUT
  public :: C_OBJECT
  public :: C_GROUP
  public :: C_SPRITE
  public :: C_TEXT
  public :: C_PARTICLES
  public :: C_FILTER
  public :: C_INSTANCE
  public :: C_SHADERDEF
  public :: C_MORPH
  public :: C_BONE
  public :: C_SKIN
  public :: C_KEYS
  public :: C_KEY
  public :: C_DIALOGUE
  public :: C_FILM

  ! ------------------------------------------------------------ limits
  real(real64), parameter :: MAX_DIM = 1000.0_real64
  integer(int64), parameter :: MIN_IMAGE = 16_int64
  integer(int64), parameter :: MAX_IMAGE = 8192_int64
  integer(int64), parameter :: MAX_OBJECTS = 10000_int64
  integer(int64), parameter :: MAX_TRIANGLES = 1000000_int64
  integer(int64), parameter :: MIN_SEGMENTS = 3_int64
  integer(int64), parameter :: MAX_SEGMENTS = 256_int64
  integer(int64), parameter :: MIN_FPS = 1_int64, MAX_FPS = 240_int64
  real(real64), parameter :: MAX_DURATION = 3600.0_real64
  real(real64), parameter :: MAX_SPEED = 10000.0_real64

  character(16), parameter :: PRIMITIVES(19) = [character(16) :: &
       "cube", "sphere", "cylinder", "plane", "pyramid", "cone", &
       "torus", "tris", "circle", "ring", "capsule", "tube", &
       "lathe", "extrude", "icosahedron", "octahedron", &
       "tetrahedron", "dodecahedron", "torusknot"]
  character(16), parameter :: GEOM_PRIMS(11) = [character(16) :: &
       "circle", "ring", "capsule", "tube", "lathe", "extrude", &
       "icosahedron", "octahedron", "tetrahedron", "dodecahedron", &
       "torusknot"]
  character(16), parameter :: MATERIALS(4) = [character(16) :: &
       "lambert", "basic", "phong", "standard"]
  character(16), parameter :: ANIM_KINDS(7) = [character(16) :: &
       "spin", "bob", "pulse", "orbit", "move", "turn", "grow"]
  ! ANIM Wave 1 (ANIM-PLAN SS1.3/SS2.4): the sentence verbs a
  ! timeline-resolved AnimStmt may carry (canonical "-s" forms and
  ! their base-form aliases).  Accepted by val_anim ONLY for anims
  ! carrying a resolved `start` field; legacy anims keep the
  ! ANIM_KINDS-only rule above, unchanged.
  character(16), parameter :: ANIM_KINDS_EXT(40) = [character(16) :: &
       "walks", "walk", "runs", "run", "enters", "enter", &
       "waves", "wave", &
       "sits", "sit", "stands", "stand", "jumps", "jump", &
       "falls", "fall", "looks", "look", "faces", "face", &
       "points", "point", "nods", "nod", "shakes", "shake", &
       "dances", "dance", "sleeps", "sleep", "smiles", "smile", &
       "picks", "pick", "gives", "give", "taps", "tap", &
       "exits", "exit"]
  character(16), parameter :: LIGHT_KINDS_V1(4) = [character(16) :: &
       "directional", "ambient", "point", "spot"]
  character(16), parameter :: CONTROLS_KINDS(2) = [character(16) :: &
       "orbit", "none"]
  ! ANIM Wave 1 FIX (easing unification): BOTH spelling families
  ! are accepted -- "ease-in/out/in-out" and "cubic-in/out/in-out"
  ! name the same curves (ANIM-PLAN SS1.8).  This registry is
  ! accept-only: it carries no canonicalisation, because the sole
  ! consumer (val_anim) passes the accepted name verbatim into the
  ! IR anim dict / .scene anim line, and the runtime evaluator
  ! (ease_value in src/animation.f90) natively switches on the
  ! cubic-* spellings -- so a newly accepted cubic-* name evaluates
  ! as the intended cubic curve with no mapping, while every
  ! previously valid ease-* name keeps its exact legacy emission
  ! (byte-identical behaviour for previously valid programs).
  character(16), parameter :: EASES(11) = [character(16) :: &
       "linear", "smooth", "in", "out", "ease", "ease-in", &
       "ease-out", "ease-in-out", "cubic-in", "cubic-out", &
       "cubic-in-out"]
  character(16), parameter :: RENDER_EXTS(2) = [character(16) :: &
       ".ppm", ".png"]
  character(16), parameter :: EXPORT_KINDS(3) = [character(16) :: &
       "json", "obj", "html"]

  integer, parameter :: DEFAULT_BG(3) = [25, 25, 35]  ! #191923
  character(3), parameter :: XYZ_CHARS = "xyz"
  character(*), parameter :: DEFAULT_OUTPUT = "output_render.ppm"

  ! ir_nodes.NAMED_COLORS (single source of truth for colours).
  character(12), parameter :: COLOR_NAMES(13) = [character(12) :: &
       "red", "green", "blue", "yellow", "magenta", "cyan", &
       "orange", "purple", "pink", "white", "black", "gray", "grey"]
  integer, parameter :: COLOR_RGB(3, 13) = reshape([ &
       220, 60, 60,   60, 220, 60,   60, 100, 240,  240, 220, 50, &
       200, 80, 220,  60, 220, 220,  240, 140, 40,  140, 80, 200, &
       240, 150, 190, 240, 240, 240, 20, 20, 25,    140, 140, 145, &
       140, 140, 145], [3, 13])

  ! Statement categories (validate._classify return values).
  integer, parameter :: C_UNKNOWN = 0, C_SCENE = 1, C_CAMERA = 2, &
       C_LIGHT = 3, C_CONTROLS = 4, C_LOAD = 5, C_ANIM = 6, &
       C_OUTPUT = 7, C_OBJECT = 8, C_GROUP = 9, C_SPRITE = 10, &
       C_TEXT = 11, C_PARTICLES = 12, C_FILTER = 13, &
       C_INSTANCE = 14, C_SHADERDEF = 15, C_MORPH = 16, &
       C_BONE = 17, C_SKIN = 18, C_KEYS = 19, C_KEY = 20, &
       C_DIALOGUE = 21, C_FILM = 22

  ! ------------------------------------------------------------- state
  ! One validate run at a time (the compiler is single-threaded);
  ! this mirrors the closure state of Python validate().
  type :: vstate
    type(error_bag_t), pointer :: bag => null()
    character(:), allocatable :: base_dir
    type(dyn) :: light_nodes, output_nodes, object_nodes
    type(dyn) :: anim_nodes, load_nodes, sprite_nodes, text_nodes
    type(dyn) :: particles_nodes, keys_header_nodes, key_nodes
    type(dyn) :: filter_nodes, instance_nodes, shader_nodes
    type(dyn) :: morph_nodes, bone_nodes, skin_nodes
    ! ANIM Wave 1: resolved dialogue survivors (marker "say"),
    ! collected by classify_node (walk_nodes has no dialogue case;
    ! see classify_node), and the film-mode flag the outputs
    ! section consults for the .mp4 gate (ANIM-PLAN SS1.9 rule 7).
    type(dyn) :: dialogue_nodes
    logical :: has_film = .false.
    logical :: has_camera = .false., has_controls = .false.
    logical :: has_scene = .false.
    type(dyn) :: camera_node, controls_node
    type(dyn) :: env_props
    character(:), allocatable :: scene_name
    ! P1: scene-level `shading smooth|flat` default (explicit only).
    character(:), allocatable :: scene_shading
    logical :: has_scene_shading = .false.
    integer(int64) :: width = 640_int64, height = 480_int64
    integer :: bg(3) = DEFAULT_BG
    type(dyn) :: names              ! dict: name -> node
    type(dyn) :: ext_stash          ! scene.extensions payloads
    integer(int64) :: total_tris = 0_int64
    type(dyn) :: ir_lights, ir_objects, ir_anims, ir_outputs
    character(:), allocatable :: last_obj_name
    logical :: has_last_obj = .false.
  end type vstate

  type(vstate) :: vs

  ! ---------------------------------------------------------------
  ! Section registry (C2): the orchestrator (f3dc_validate) builds
  ! an explicit dispatch table of per-statement-family section
  ! validators and walks it in registration order -- the same
  ! name + procedure-pointer pattern as f3dc_ir's extension
  ! registry.  Registration order IS diagnostic order: sections
  ! run exactly in the sequence the monolithic validate_program
  ! ran them.  All sections share the uniform no-arg signature
  ! because every input/output lives in vs / vctx (module state,
  ! mirroring the Python validate() closure).
  ! ---------------------------------------------------------------
  abstract interface
    subroutine val_section_iface()
    end subroutine val_section_iface
  end interface

  type :: val_entry
    character(:), allocatable :: name
    procedure(val_section_iface), pointer, nopass :: fn => null()
  end type val_entry

  type(val_entry), allocatable :: val_registry(:)
  integer :: n_val_registry = 0

  !> Cross-section results that are not part of vs: the IR camera
  !! dict built by the camera section and consumed by the
  !! orchestrator's result assembly.
  type :: val_ctx
    type(dyn) :: ir_camera
  end type val_ctx
  type(val_ctx) :: vctx

contains

  ! ================================================================
  ! Generic adapters (validate.py: _get / _props_dict / _field /
  ! _num / _int / _vec3 / _span / _err)
  ! ================================================================

  !> Python _get(obj, *names): first present, non-None value among
  !! the names on the node dict; dyn_null when none applies.
  subroutine vget(node, names, val)
    type(dyn), intent(in) :: node
    character(*), intent(in) :: names(:)
    type(dyn), intent(out) :: val
    integer :: k
    val = dyn_null()
    if (node%kind /= DYN_K_DICT) return
    do k = 1, size(names)
      if (dyn_dict_has(node, trim(names(k)))) then
        val = dyn_dict_get(node, trim(names(k)))
        if (val%kind /= DYN_K_NULL) return
        val = dyn_null()
      end if
    end do
  end subroutine vget


  !> Python _field(node, props, *names): node first, then props.
  subroutine vfield(node, props, names, val)
    type(dyn), intent(in) :: node, props
    character(*), intent(in) :: names(:)
    type(dyn), intent(out) :: val
    call vget(node, names, val)
    if (val%kind /= DYN_K_NULL) return
    call vget(props, names, val)
  end subroutine vfield


  !> Python str(key) for dict keys / scalar interpolation.
  recursive function py_str(val) result(out)
    type(dyn), intent(in) :: val
    character(:), allocatable :: out
    integer :: k
    type(str_builder) :: sb
    select case (val%kind)
    case (DYN_K_STR)
      out = val%s
    case (DYN_K_BOOL)
      if (val%b) then
        out = "True"
      else
        out = "False"
      end if
    case (DYN_K_INT)
      out = fmt_int(val%i)
    case (DYN_K_REAL)
      out = fmt_real(val%r)
    case (DYN_K_LIST)
      ! AST sequences are Python tuples; str(tuple) uses parens.
      call sb_init(sb)
      call sb_add(sb, "(")
      do k = 1, dyn_list_len(val)
        if (k > 1) call sb_add(sb, ", ")
        call sb_add(sb, py_repr(dyn_list_at(val, k)))
      end do
      if (dyn_list_len(val) == 1) call sb_add(sb, ",")
      call sb_add(sb, ")")
      out = sb_text(sb)
    case (DYN_K_DICT)
      call sb_init(sb)
      call sb_add(sb, "{")
      do k = 1, dyn_dict_len(val)
        if (k > 1) call sb_add(sb, ", ")
        call sb_add(sb, py_repr(dyn_str(dyn_dict_key_at(val, k))) // &
              ": " // py_repr(dyn_dict_value_at(val, k)))
      end do
      call sb_add(sb, "}")
      out = sb_text(sb)
    case default
      out = "None"
    end select
  end function py_str


  !> Python repr() of a string: quote choice + escapes.
  function repr_str(s) result(out)
    character(*), intent(in) :: s
    character(:), allocatable :: out
    type(str_builder) :: sb
    character :: quote
    integer :: k, c
    logical :: has_sq, has_dq
    has_sq = index(s, "'") > 0
    has_dq = index(s, '"') > 0
    if (has_sq .and. .not. has_dq) then
      quote = '"'
    else
      quote = "'"
    end if
    call sb_init(sb)
    do k = 1, len(s)
      c = iachar(s(k:k))
      if (s(k:k) == "\") then
        call sb_add(sb, "\\")
      else if (s(k:k) == quote) then
        call sb_add(sb, "\" // quote)
      else if (c == 10) then
        call sb_add(sb, "\n")
      else if (c == 13) then
        call sb_add(sb, "\r")
      else if (c == 9) then
        call sb_add(sb, "\t")
      else if (c < 32 .or. c == 127) then
        call sb_add(sb, "\x" // hex2(c))
      else
        call sb_add(sb, s(k:k))
      end if
    end do
    out = quote // sb_text(sb) // quote
  end function repr_str


  function hex2(c) result(out)
    integer, intent(in) :: c
    character(2) :: out
    character(16), parameter :: HD = "0123456789abcdef"
    out(1:1) = HD(c / 16 + 1:c / 16 + 1)
    out(2:2) = HD(mod(c, 16) + 1:mod(c, 16) + 1)
  end function hex2


  !> Python repr() of a dyn value (%r in validate.py messages).
  recursive function py_repr(val) result(out)
    type(dyn), intent(in) :: val
    character(:), allocatable :: out
    if (val%kind == DYN_K_STR) then
      out = repr_str(val%s)
    else
      out = py_str(val)
    end if
  end function py_repr


  !> Python truthiness of a dyn value.
  pure logical function py_truthy(val)
    type(dyn), intent(in) :: val
    select case (val%kind)
    case (DYN_K_NULL)
      py_truthy = .false.
    case (DYN_K_BOOL)
      py_truthy = val%b
    case (DYN_K_INT)
      py_truthy = val%i /= 0_int64
    case (DYN_K_REAL)
      py_truthy = val%r /= 0.0_real64
    case (DYN_K_STR)
      py_truthy = len(val%s) > 0
    case (DYN_K_LIST)
      py_truthy = dyn_list_len(val) > 0
    case (DYN_K_DICT)
      py_truthy = dyn_dict_len(val) > 0
    case default
      py_truthy = .false.
    end select
  end function py_truthy


  !> Python _props_dict(node): normalised props (lower-cased keys).
  function props_of(node) result(props)
    type(dyn), intent(in) :: node
    type(dyn) :: props, raw, item, keyv, valv
    character(:), allocatable :: key
    integer :: k
    props = dyn_dict()
    call vget(node, [character(12) :: "props", "properties", &
                     "options", "args"], raw)
    if (raw%kind == DYN_K_DICT) then
      do k = 1, dyn_dict_len(raw)
        key = to_lower(py_str(dyn_str(dyn_dict_key_at(raw, k))))
        call dyn_dict_set(props, key, dyn_dict_value_at(raw, k))
      end do
    else if (raw%kind == DYN_K_LIST) then
      do k = 1, dyn_list_len(raw)
        item = dyn_list_at(raw, k)
        if (item%kind == DYN_K_LIST .and. dyn_list_len(item) == 2) then
          key = to_lower(py_str(dyn_list_at(item, 1)))
          call dyn_dict_set(props, key, dyn_list_at(item, 2))
        else
          call vget(item, [character(8) :: "name", "key"], keyv)
          if (keyv%kind /= DYN_K_NULL) then
            call vget(item, [character(8) :: "value", "val"], valv)
            key = to_lower(py_str(keyv))
            call dyn_dict_set(props, key, valv)
          end if
        end if
      end do
    end if
  end function props_of


  !> Python _num(value): float(value) or absent.  Bools are absent.
  subroutine get_num(val, x, has)
    type(dyn), intent(in) :: val
    real(real64), intent(out) :: x
    logical, intent(out) :: has
    x = 0.0_real64
    has = .false.
    select case (val%kind)
    case (DYN_K_INT)
      x = real(val%i, real64)
      has = .true.
    case (DYN_K_REAL)
      x = val%r
      has = .true.
    case (DYN_K_STR)
      call str_to_real(val%s, x, has)
    end select
  end subroutine get_num


  !> Python float(str) for the spellings that can reach _num.
  subroutine str_to_real(s, x, ok)
    character(*), intent(in) :: s
    real(real64), intent(out) :: x
    logical, intent(out) :: ok
    character(:), allocatable :: t, u
    integer :: ios, k
    ok = .false.
    x = 0.0_real64
    t = strip_ws(s)
    u = to_lower(t)
    if (u == "inf" .or. u == "+inf" .or. u == "infinity" .or. &
        u == "+infinity") then
      x = ieee_value(0.0_real64, ieee_positive_inf)
      ok = .true.
      return
    end if
    if (u == "-inf" .or. u == "-infinity") then
      x = -ieee_value(0.0_real64, ieee_positive_inf)
      ok = .true.
      return
    end if
    if (u == "nan" .or. u == "+nan" .or. u == "-nan") then
      x = ieee_value(0.0_real64, ieee_quiet_nan)
      ok = .true.
      return
    end if
    ! Python float() accepts underscores between digits; drop them,
    ! and reject any other unexpected character up front.
    block
      character(:), allocatable :: v
      type(str_builder) :: sb
      call sb_init(sb)
      do k = 1, len(t)
        if (t(k:k) == "_") cycle
        if (index("0123456789.+-eE", t(k:k)) == 0) return
        call sb_add(sb, t(k:k))
      end do
      v = sb_text(sb)
      if (len(v) == 0) return
      read (v, *, iostat=ios) x
      if (ios /= 0) then
        x = 0.0_real64
        return
      end if
      ok = .true.
    end block
  end subroutine str_to_real


  !> Python str.strip() (whitespace both ends).
  function strip_ws(s) result(out)
    character(*), intent(in) :: s
    character(:), allocatable :: out
    integer :: a, b
    a = 1
    b = len(s)
    do while (a <= b)
      if (.not. is_ws(s(a:a))) exit
      a = a + 1
    end do
    do while (b >= a)
      if (.not. is_ws(s(b:b))) exit
      b = b - 1
    end do
    if (a > b) then
      out = ""
    else
      out = s(a:b)
    end if
  end function strip_ws


  pure logical function is_ws(c)
    character, intent(in) :: c
    integer :: code
    code = iachar(c)
    is_ws = code == 32 .or. (code >= 9 .and. code <= 13)
  end function is_ws


  !> Python _int(value): int(float(value)) or absent.
  subroutine get_int(val, i, has)
    type(dyn), intent(in) :: val
    integer(int64), intent(out) :: i
    logical, intent(out) :: has
    real(real64) :: x
    call get_num(val, x, has)
    if (.not. has) then
      i = 0_int64
      return
    end if
    if (.not. ieee_is_finite(x)) then
      ! Python int(inf) raises; _int callers only reach this via
      ! int(number) on a finite-checked path in practice.
      has = .false.
      i = 0_int64
      return
    end if
    i = int(x, int64)
  end subroutine get_int


  !> Python _vec3(value): (x, y, z) floats or absent.
  subroutine get_vec3(val, vec, has)
    type(dyn), intent(in) :: val
    real(real64), intent(out) :: vec(3)
    logical, intent(out) :: has
    type(dyn) :: part
    integer :: k
    real(real64) :: comp
    logical :: okc
    vec = 0.0_real64
    has = .false.
    if (val%kind == DYN_K_LIST .and. dyn_list_len(val) >= 3) then
      do k = 1, 3
        call get_num(dyn_list_at(val, k), comp, okc)
        if (.not. okc) return
        vec(k) = comp
      end do
      has = .true.
      return
    end if
    if (val%kind == DYN_K_DICT) then
      do k = 1, 3
        part = dyn_dict_get(val, XYZ_CHARS(k:k))
        call get_num(part, comp, okc)
        if (.not. okc) return
        vec(k) = comp
      end do
      has = .true.
    end if
  end subroutine get_vec3


  !> Python _vec3(value, default).
  subroutine vec3_or(val, def, vec)
    type(dyn), intent(in) :: val
    real(real64), intent(in) :: def(3)
    real(real64), intent(out) :: vec(3)
    logical :: has
    call get_vec3(val, vec, has)
    if (.not. has) vec = def
  end subroutine vec3_or


  ! ================================================================
  ! Typed accessor bridge (v3.0 Phase 6 C1)
  !
  ! A strict, kind-tagged layer over the dyn readers above, for
  ! callers that want the value's own type instead of the Python
  ! coercions in get_num / get_int (which accept numeric strings).
  ! No coercion happens here: kind_tag is the stored value's kind,
  ! mirroring f3dc_dyn's DYN_K_* constants (DYN_K_NULL / _BOOL /
  ! _INT / _REAL / _STR / _LIST / _DICT), and only the output slot
  ! matching kind_tag is meaningful -- the other slots keep the
  ! defaults set on entry (0 / 0.0 / .false. / "").  Lookup mirrors
  ! vget for a single key: node must be a dict, and a key that is
  ! absent or stored null counts as not found.  LIST / DICT values
  ! report found with their kind_tag and no scalar payload, so a
  ! caller can branch on the tag and fall back to the dyn helpers.
  ! ================================================================

  subroutine vget_scalar(node, key, kind_tag, ival, rval, bval, &
                         sval, found)
    type(dyn), intent(in) :: node
    character(*), intent(in) :: key
    integer, intent(out) :: kind_tag
    integer(int64), intent(out) :: ival
    real(real64), intent(out) :: rval
    logical, intent(out) :: bval
    character(:), allocatable, intent(out) :: sval
    logical, intent(out) :: found
    type(dyn) :: val
    kind_tag = DYN_K_NULL
    ival = 0_int64
    rval = 0.0_real64
    bval = .false.
    sval = ""
    found = .false.
    if (node%kind /= DYN_K_DICT) return
    if (.not. dyn_dict_has(node, key)) return
    val = dyn_dict_get(node, key)
    if (val%kind == DYN_K_NULL) return
    kind_tag = val%kind
    found = .true.
    select case (val%kind)
    case (DYN_K_BOOL)
      bval = val%b
    case (DYN_K_INT)
      ival = val%i
    case (DYN_K_REAL)
      rval = val%r
    case (DYN_K_STR)
      if (allocated(val%s)) then
        sval = val%s
      end if
    case default
      ! LIST / DICT: kind_tag alone is the result; the scalar
      ! slots keep their defaults above.
    end select
  end subroutine vget_scalar


  !> Typed vec3 sibling of vget_scalar: the value under key on
  !! node, read as three scalar components through get_vec3 (a
  !! 3+ list of numbers / numeric strings, or an x/y/z dict).
  !! vals is all-zero when found is .false. -- unlike get_vec3,
  !! which can leave earlier components set on a partial read.
  subroutine vget_vec3_typed(node, key, vals, found)
    type(dyn), intent(in) :: node
    character(*), intent(in) :: key
    real(real64), intent(out) :: vals(3)
    logical, intent(out) :: found
    type(dyn) :: val
    vals = 0.0_real64
    found = .false.
    if (node%kind /= DYN_K_DICT) return
    if (.not. dyn_dict_has(node, key)) return
    val = dyn_dict_get(node, key)
    if (val%kind == DYN_K_NULL) return
    call get_vec3(val, vals, found)
    if (.not. found) vals = 0.0_real64
  end subroutine vget_vec3_typed


  pure logical function finite_vec(vec)
    real(real64), intent(in) :: vec(3)
    finite_vec = all([ieee_is_finite(vec(1)), ieee_is_finite(vec(2)), &
                      ieee_is_finite(vec(3))])
  end function finite_vec


  !> Node span: only a genuine span dict counts (see header note).
  subroutine node_span(node, sp, has)
    type(dyn), intent(in) :: node
    type(span_t), intent(out) :: sp
    logical, intent(out) :: has
    type(dyn) :: sv, lv
    integer(int64) :: line, col, length
    logical :: okl, okc, okl2
    has = .false.
    if (node%kind /= DYN_K_DICT) return
    sv = dyn_dict_get(node, "span")
    if (sv%kind /= DYN_K_DICT) return
    lv = dyn_dict_get(sv, "source")
    if (lv%kind /= DYN_K_STR) return
    call get_int(dyn_dict_get(sv, "line"), line, okl)
    call get_int(dyn_dict_get(sv, "col"), col, okc)
    if (.not. (okl .and. okc)) return
    call get_int(dyn_dict_get(sv, "length"), length, okl2)
    if (.not. okl2) length = 1_int64
    sp = make_span(lv%s, int(line), int(col), int(length))
    has = .true.
  end subroutine node_span


  !> Python _err(bag, code, message, span): severity error, no
  !! why/help (validate.py's _err builds the Diagnostic that way).
  subroutine verr(code, msg)
    character(*), intent(in) :: code, msg
    call error_bag_add(vs%bag, make_diagnostic(code, "error", msg))
  end subroutine verr


  subroutine verrn(code, msg, node)
    character(*), intent(in) :: code, msg
    type(dyn), intent(in) :: node
    type(span_t) :: sp
    logical :: has
    call node_span(node, sp, has)
    if (has) then
      call error_bag_add(vs%bag, &
           make_diagnostic_span(code, "error", msg, sp))
    else
      call verr(code, msg)
    end if
  end subroutine verrn


  !> ANIM Wave 1: an error carrying why/help lines (ANIM-PLAN
  !! SS2.4: the timeline diagnostics populate why/help properly
  !! rather than inheriting the validator's span-less style debt).
  !! The span is attached when the node carries a real one, exactly
  !! as verrn does.
  subroutine verr_full(code, msg, node, why, help)
    character(*), intent(in) :: code, msg, why, help
    type(dyn), intent(in) :: node
    type(span_t) :: sp
    logical :: has
    call node_span(node, sp, has)
    if (has) then
      call error_bag_add(vs%bag, make_diagnostic_span( &
           code, "error", msg, sp, why, help))
    else
      call error_bag_add(vs%bag, make_diagnostic( &
           code, "error", msg, why, help))
    end if
  end subroutine verr_full


  !> Warning sibling of verr_full (W203/W204).
  subroutine vwarn_full(code, msg, node, why, help)
    character(*), intent(in) :: code, msg, why, help
    type(dyn), intent(in) :: node
    type(span_t) :: sp
    logical :: has
    call node_span(node, sp, has)
    if (has) then
      call error_bag_add(vs%bag, make_diagnostic_span( &
           code, "warning", msg, sp, why, help))
    else
      call error_bag_add(vs%bag, make_diagnostic( &
           code, "warning", msg, why, help))
    end if
  end subroutine vwarn_full


  !> ANIM Wave 1: is this program a film (ANIM-PLAN SS1.1)?  The
  !! primary signal is the film node (classify_node sets
  !! vs%has_film when it sees the "film_def" marker).  Because
  !! desugar owns the resolved stream, the resolved survivors are
  !! accepted as equivalent proof: a dialogue node, an anim
  !! carrying a resolved `start` field, or an "@camera" keys
  !! header can only exist in a film.  Used by the outputs
  !! section's .mp4 gate (SS1.9 rule 7); legacy programs have none
  !! of these signals, so their behaviour is unchanged.
  logical function program_is_film()
    type(dyn) :: node, props, v
    integer :: k
    program_is_film = .true.
    if (vs%has_film) return
    if (dyn_list_len(vs%dialogue_nodes) > 0) return
    do k = 1, dyn_list_len(vs%anim_nodes)
      node = dyn_list_at(vs%anim_nodes, k)
      if (dyn_dict_has(node, "start")) return
      props = props_of(node)
      if (dyn_dict_has(props, "start")) return
    end do
    do k = 1, dyn_list_len(vs%keys_header_nodes)
      node = dyn_list_at(vs%keys_header_nodes, k)
      props = props_of(node)
      call vfield(node, props, [character(12) :: "target"], v)
      if (v%kind == DYN_K_STR) then
        if (v%s == "@camera") return
      end if
    end do
    program_is_film = .false.
  end function program_is_film


  !> Ints formatted the way Python %s renders them.
  function istr(i) result(out)
    integer(int64), intent(in) :: i
    character(:), allocatable :: out
    out = fmt_int(i)
  end function istr


  function rstr(x) result(out)
    real(real64), intent(in) :: x
    character(:), allocatable :: out
    out = fmt_real(x)
  end function rstr


  !> ", ".join of a fixed word list (Python ", ".join(TUPLE)).
  function join_words(words) result(out)
    character(*), intent(in) :: words(:)
    character(:), allocatable :: out
    integer :: k
    type(str_builder) :: sb
    call sb_init(sb)
    do k = 1, size(words)
      if (k > 1) call sb_add(sb, ", ")
      call sb_add(sb, trim(words(k)))
    end do
    out = sb_text(sb)
  end function join_words


  logical function in_words(word, words)
    character(*), intent(in) :: word
    character(*), intent(in) :: words(:)
    integer :: k
    in_words = .false.
    do k = 1, size(words)
      if (word == trim(words(k))) then
        in_words = .true.
        return
      end if
    end do
  end function in_words


  !> dyn list of 3 reals / 3 ints (IR tuple fields).
  function vec3_dyn(vec) result(out)
    real(real64), intent(in) :: vec(3)
    type(dyn) :: out
    out = dyn_list()
    call dyn_list_push(out, dyn_real(vec(1)))
    call dyn_list_push(out, dyn_real(vec(2)))
    call dyn_list_push(out, dyn_real(vec(3)))
  end function vec3_dyn


  function rgb_dyn(rgb) result(out)
    integer, intent(in) :: rgb(3)
    type(dyn) :: out
    out = dyn_list()
    call dyn_list_push(out, dyn_int(int(rgb(1), int64)))
    call dyn_list_push(out, dyn_int(int(rgb(2), int64)))
    call dyn_list_push(out, dyn_int(int(rgb(3), int64)))
  end function rgb_dyn



  ! ================================================================
  ! Colours (validate.py _parse_color; the string grammar itself
  ! is ir_nodes.parse_color, delegated to f3dc_ir.ir_parse_color)
  ! ================================================================

  !> validate.py _parse_color(raw, bag, span): resolve any colour
  !! spelling to rgb, or has=.false. (diagnostics already recorded,
  !! except where Python records none: raw None).
  recursive subroutine parse_color_val(raw, node, rgb, has)
    type(dyn), intent(in) :: raw, node
    integer, intent(out) :: rgb(3)
    logical, intent(out) :: has
    type(dyn) :: named, rgbv, part
    integer :: k, before
    integer(int64) :: ch
    logical :: okc
    character(:), allocatable :: text, low
    has = .false.
    rgb = 0
    if (raw%kind == DYN_K_NULL) return
    if (raw%kind == DYN_K_LIST) then
      if (dyn_list_len(raw) /= 3) then
        call verrn("E202", "a colour needs exactly 3 parts " // &
                 "(red, green, blue)", node)
        return
      end if
      do k = 1, 3
        part = dyn_list_at(raw, k)
        call get_int(part, ch, okc)
        if (.not. okc .or. ch < 0_int64 .or. ch > 255_int64) then
          call verrn("E202", "colour part " // py_repr(part) // &
               " must be a whole number from 0 to 255", node)
          return
        end if
        rgb(k) = int(ch)
      end do
      has = .true.
      return
    end if
    if (raw%kind /= DYN_K_STR) then
      ! ColourLit-style node: name/value/rgb attributes.
      call vget(raw, [character(8) :: "name", "value", "text"], named)
      call vget(raw, [character(8) :: "rgb", "channels", "color", &
                      "colour"], rgbv)
      if (rgbv%kind /= DYN_K_NULL) then
        call parse_color_val(rgbv, node, rgb, has)
        return
      end if
      if (named%kind == DYN_K_NULL) then
        call verrn("E202", "that colour cannot be read", node)
        return
      end if
      if (named%kind /= DYN_K_STR) then
        call verrn("E202", "that colour cannot be read", node)
        return
      end if
      text = named%s
    else
      text = raw%s
    end if
    text = strip_ws(text)
    low = to_lower(text)
    do k = 1, size(COLOR_NAMES)
      if (low == trim(COLOR_NAMES(k))) then
        rgb = COLOR_RGB(:, k)
        has = .true.
        return
      end if
    end do
    before = error_bag_error_count(vs%bag)
    block
      type(dyn) :: res
      logical :: is_null
      ! ir_nodes.parse_color(text, bag, span), via f3dc_ir.
      call ir_parse_color(dyn_str(text), vs%bag, res, is_null)
      if (.not. is_null) then
        ! Python: return _parse_color(result) -- the channel check.
        call parse_color_val(res, node, rgb, has)
        return
      end if
    end block
    if (error_bag_error_count(vs%bag) == before) then
      call verrn("E202", "there is no colour called " // &
           repr_str(text), node)
    end if
  end subroutine parse_color_val


  ! ================================================================
  ! Statement classification + children (validate.py _classify /
  ! _children / _statements) -- see the header note on dyn shapes.
  ! ================================================================

  subroutine classify_node(node, cat)
    type(dyn), intent(in) :: node
    integer, intent(out) :: cat
    type(dyn) :: props, kv
    character(:), allocatable :: kind
    cat = C_UNKNOWN
    if (node%kind /= DYN_K_DICT) return
    ! ANIM Wave 1 (ANIM-PLAN SS2.1/SS2.6): the new marker keys are
    ! checked FIRST, before every older signature, so a new node
    ! can never be swallowed by one -- a dialogue node carries
    ! "content" (the C_TEXT signature), a cue carries
    ! "target"+"loop" (the C_KEYS signature), a cammove can carry
    ! camera-shaped fields.  Only two survivors of desugar reach
    ! the validator: dialogue (marker "say") and the film header.
    ! walk_nodes (f3dc_val_object) has no case for the new
    ! categories, so classify_node itself collects dialogue nodes
    ! into vs%dialogue_nodes and records the film flag in
    ! vs%has_film; classify_node is called exactly once per node
    ! by the walk, so the collection cannot double-count.  The
    ! remaining markers never survive desugar (SS2.2); if one is
    ! seen anyway it is C_UNKNOWN (ignored), never misclassified.
    if (dyn_dict_has(node, "say")) then
      cat = C_DIALOGUE
      if (vs%dialogue_nodes%kind == DYN_K_LIST) &
        call dyn_list_push(vs%dialogue_nodes, node)
      return
    end if
    if (dyn_dict_has(node, "film_def")) then
      cat = C_FILM
      vs%has_film = .true.
      return
    end if
    if (dyn_dict_has(node, "char_def") .or. &
        dyn_dict_has(node, "action_def") .or. &
        dyn_dict_has(node, "timeline_def") .or. &
        dyn_dict_has(node, "cue") .or. &
        dyn_dict_has(node, "cam_move") .or. &
        dyn_dict_has(node, "transition") .or. &
        dyn_dict_has(node, "loop_block") .or. &
        dyn_dict_has(node, "let_name")) then
      cat = C_UNKNOWN
      return
    end if
    if (dyn_dict_has(node, "amount")) then
      cat = C_FILTER
      return
    end if
    if (dyn_dict_has(node, "expr")) then
      cat = C_SHADERDEF
      return
    end if
    if (dyn_dict_has(node, "factor")) then
      cat = C_MORPH
      return
    end if
    if (dyn_dict_has(node, "bone")) then
      cat = C_SKIN
      return
    end if
    if (dyn_dict_has(node, "source")) then
      cat = C_INSTANCE
      return
    end if
    if (dyn_dict_has(node, "time")) then
      cat = C_KEY
      return
    end if
    if (dyn_dict_has(node, "target") .and. &
        dyn_dict_has(node, "loop") .and. &
        .not. dyn_dict_has(node, "kind")) then
      cat = C_KEYS
      return
    end if
    if (dyn_dict_has(node, "bg")) then
      cat = C_SCENE
      return
    end if
    if (dyn_dict_has(node, "content")) then
      cat = C_TEXT
      return
    end if
    if (dyn_dict_has(node, "name") .and. &
        dyn_dict_has(node, "colour") .and. &
        .not. dyn_dict_has(node, "prim")) then
      props = props_of(node)
      if (dyn_dict_has(props, "count") .or. &
          dyn_dict_has(props, "life") .or. &
          dyn_dict_has(props, "speed") .or. &
          dyn_dict_has(props, "spread") .or. &
          dyn_dict_has(props, "gravity") .or. &
          dyn_dict_has(props, "seed")) then
        cat = C_PARTICLES
      else
        cat = C_SPRITE
      end if
      return
    end if
    if (dyn_dict_has(node, "name") .and. &
        dyn_dict_has(node, "props") .and. &
        .not. dyn_dict_has(node, "colour") .and. &
        .not. dyn_dict_has(node, "color") .and. &
        .not. dyn_dict_has(node, "prim") .and. &
        .not. dyn_dict_has(node, "path")) then
      cat = C_BONE
      return
    end if
    if (dyn_dict_has(node, "fov")) then
      cat = C_CAMERA
      return
    end if
    if (dyn_dict_has(node, "direction") .or. &
        dyn_dict_has(node, "from_") .or. &
        (dyn_dict_has(node, "kind") .and. &
         dyn_dict_has(node, "intensity"))) then
      cat = C_LIGHT
      return
    end if
    if (dyn_dict_has(node, "autorotate")) then
      cat = C_CONTROLS
      return
    end if
    if (dyn_dict_has(node, "path") .and. &
        dyn_dict_has(node, "file") .and. &
        .not. dyn_dict_has(node, "format") .and. &
        .not. dyn_dict_has(node, "still")) then
      cat = C_LOAD
      return
    end if
    call vget(node, [character(12) :: "kind", "type", "prim", &
                     "primitive", "stmt_kind"], kv)
    kind = ""
    if (kv%kind /= DYN_K_NULL) kind = to_lower(py_str(kv))
    if (dyn_dict_has(node, "verb")) then
      cat = C_ANIM
      return
    end if
    if (in_words(kind, ANIM_KINDS) .and. &
        dyn_dict_has(node, "target") .and. &
        .not. dyn_dict_has(node, "prim")) then
      cat = C_ANIM
      return
    end if
    if (dyn_dict_has(node, "still") .or. &
        dyn_dict_has(node, "format")) then
      cat = C_OUTPUT
      return
    end if
    if (kind == "render" .or. kind == "export") then
      cat = C_OUTPUT
      return
    end if
    if (dyn_dict_has(node, "prim")) then
      cat = C_OBJECT
      return
    end if
    if (dyn_dict_has(node, "body") .or. dyn_dict_has(node, "obj") &
        .or. kind == "group" .or. kind == "repeat" .or. &
        kind == "grid" .or. kind == "ring") then
      cat = C_GROUP
      return
    end if
    if (kind == "scene") then
      cat = C_SCENE
      return
    end if
    if (in_words(kind, PRIMITIVES) .or. kind == "tris") then
      cat = C_OBJECT
      return
    end if
  end subroutine classify_node


  !> Python _children(node): first non-None of body / children /
  !! statements / objects, as a list (an empty list still counts).
  function children_of(node) result(out)
    type(dyn), intent(in) :: node
    type(dyn) :: out, v
    integer :: k
    character(12) :: keys(4)
    out = dyn_list()
    keys = [character(12) :: "body", "children", "statements", &
            "objects"]
    if (node%kind /= DYN_K_DICT) return
    do k = 1, 4
      if (dyn_dict_has(node, trim(keys(k)))) then
        v = dyn_dict_get(node, trim(keys(k)))
        if (v%kind == DYN_K_LIST) then
          call dyn_assign(out, v)
          return
        end if
        if (v%kind /= DYN_K_NULL) return
      end if
    end do
  end function children_of


  !> Python _statements(program).
  function statements_of(program) result(out)
    type(dyn), intent(in) :: program
    type(dyn) :: out, v
    character(12) :: keys(6)
    integer :: k
    keys = [character(12) :: "statements", "body", "lines", &
            "stmts", "items", "children"]
    out = dyn_list()
    if (program%kind == DYN_K_DICT) then
      do k = 1, 6
        if (dyn_dict_has(program, trim(keys(k)))) then
          v = dyn_dict_get(program, trim(keys(k)))
          if (v%kind == DYN_K_LIST) then
            call dyn_assign(out, v)
            return
          end if
          if (v%kind /= DYN_K_NULL) exit
        end if
      end do
    end if
    if (program%kind == DYN_K_NULL) return
    call dyn_list_push(out, dyn_copy(program))
  end function statements_of


  ! ================================================================
  ! Range checks (validate.py _check_dim / _check_image_dim)
  ! ================================================================

  subroutine check_dim(label, x, has, node)
    character(*), intent(in) :: label
    real(real64), intent(in) :: x
    logical, intent(in) :: has
    type(dyn), intent(in), optional :: node
    if (.not. has) return
    if (.not. ieee_is_finite(x) .or. x <= 0.0_real64 .or. &
        x > MAX_DIM) then
      if (present(node)) then
        call verrn("E301", label // " is " // rstr(x) // &
             ", but it must be more than 0 and at most " // &
             istr(int(MAX_DIM, int64)), node)
      else
        call verr("E301", label // " is " // rstr(x) // &
             ", but it must be more than 0 and at most " // &
             istr(int(MAX_DIM, int64)))
      end if
    end if
  end subroutine check_dim


  subroutine check_image_dim(label, value, has, node)
    character(*), intent(in) :: label
    integer(int64), intent(in) :: value
    logical, intent(in) :: has
    type(dyn), intent(in), optional :: node
    character(:), allocatable :: msg
    if (.not. has) return
    if (value < MIN_IMAGE .or. value > MAX_IMAGE) then
      msg = label // " is " // istr(value) // &
           ", but each picture side must be " // istr(MIN_IMAGE) // &
           " to " // istr(MAX_IMAGE) // " pixels"
      if (present(node)) then
        call verrn("E301", msg, node)
      else
        call verr("E301", msg)
      end if
    end if
  end subroutine check_image_dim


  !> os.path.join(base_dir, path) for a relative path (POSIX).
  function join_path(base, path) result(out)
    character(*), intent(in) :: base, path
    character(:), allocatable :: out
    if (len(base) == 0) then
      out = path
    else if (base(len(base):len(base)) == "/") then
      out = base // path
    else
      out = base // "/" // path
    end if
  end function join_path


  logical function path_is_file(path)
    character(*), intent(in) :: path
    inquire (file=path, exist=path_is_file)
  end function path_is_file


  !> Lower-cased extension of a path, os.path.splitext style.
  function path_ext_lower(path) result(out)
    character(*), intent(in) :: path
    character(:), allocatable :: out
    integer :: slash, dot
    slash = index(path, "/", back=.true.)
    dot = index(path, ".", back=.true.)
    if (dot <= slash + 1 .or. dot == 0) then
      out = ""
    else
      out = to_lower(path(dot:))
    end if
  end function path_ext_lower


  !> Python scene.extensions[key] = payload, only when the payload
  !! dict is non-empty (the env payload itself is a
  !! DISPATCH(ext_lights_env) product, still deferred).
  !! ANIM Wave 1: a non-empty LIST payload is also accepted -- the
  !! timeline section's "dialogue" extension is a list of cue
  !! dicts (ANIM-PLAN SS2.3).  Existing dict callers are
  !! unaffected: a dict still needs at least one entry.
  subroutine set_scene_extension(key, payload)
    character(*), intent(in) :: key
    type(dyn), intent(in) :: payload
    if (payload%kind == DYN_K_LIST) then
      if (dyn_list_len(payload) == 0) return
    else if (dyn_dict_len(payload) == 0) then
      return
    end if
    call dyn_dict_set(vs%ext_stash, key, payload)
  end subroutine set_scene_extension

  ! ---------------------------------------------------------------
  ! Registry machinery (mirrors f3dc_ir's register/run_all pair).
  ! ---------------------------------------------------------------
  subroutine val_reset_registry()
    if (allocated(val_registry)) deallocate (val_registry)
    n_val_registry = 0
  end subroutine val_reset_registry

  subroutine val_register(name, fn)
    character(*), intent(in) :: name
    procedure(val_section_iface) :: fn
    type(val_entry), allocatable :: tmp(:)
    integer :: k
    do k = 1, n_val_registry
      if (allocated(val_registry(k)%name)) then
        if (val_registry(k)%name == name) then
          val_registry(k)%fn => fn
          return
        end if
      end if
    end do
    if (.not. allocated(val_registry)) allocate (val_registry(0))
    if (n_val_registry >= size(val_registry)) then
      allocate (tmp(max(4, 2 * size(val_registry))))
      do k = 1, n_val_registry
        if (allocated(val_registry(k)%name)) &
          tmp(k)%name = val_registry(k)%name
        tmp(k)%fn => val_registry(k)%fn
      end do
      call move_alloc(tmp, val_registry)
    end if
    n_val_registry = n_val_registry + 1
    val_registry(n_val_registry)%name = name
    val_registry(n_val_registry)%fn => fn
  end subroutine val_register

  subroutine val_run_sections()
    integer :: k
    do k = 1, n_val_registry
      if (associated(val_registry(k)%fn)) &
        call val_registry(k)%fn()
    end do
  end subroutine val_run_sections

end module f3dc_val_common
