! f3dc_validate -- Forge3D validator: desugared AST -> frozen typed IR.
!
! Faithful Fortran port of tools/f3dc/validate.py (seat B09), per
! compiler/DESIGN.md.  Python is the oracle: every check, every E/W
! code, message text, diagnostic ordering and did-you-mean behaviour
! of validate.py is mirrored function-by-function below.
!
! ---------------------------------------------------------------------
! Entry point (mirrors Python  validate(program, bag, base_dir=".")
! -> IRScene | None, as called by cli.py's compile_pipeline):
!
!   subroutine validate_program(program, bag, base_dir, scene, ok)
!     type(dyn), intent(in)           :: program   ! parser Program node
!     type(error_bag_t), intent(inout):: bag
!     character(*), intent(in)        :: base_dir  ! dir of the .f3d file
!     type(dyn), intent(out)          :: scene     ! IRScene dyn dict
!     logical, intent(out)            :: ok        ! .false. == Python None
!
! The IR is a dyn DICT with exactly the ir_nodes.py dataclass fields
! (IRScene: name, width, height, bg, camera, lights, objects,
! animations, outputs, extensions, source_map; tuples become dyn
! lists) -- the same representation f3dc_ir uses.  Colour parsing of
! strings is delegated to f3dc_ir's ir_parse_color (ir_nodes.py owns
! NAMED_COLORS and parse_color); validate.py's own list / node
! colour handling stays here, as in the Python module.
!
! Sibling interface used for the desugar pass (f3dc_desugar, landed
! in parallel; entry point desugar(program_in, bag, base_dir,
! program_out) -- base_dir added in v2.0 P3 for import resolution):
!
! ---------------------------------------------------------------------
! AST class names in dyn-land: Python _classify() dispatches on
! type(node).__name__, which dyn dicts do not carry.  classify_node()
! below reproduces the same categories from the dict key sets the
! parser/desugar actually emit (verified against the Python oracle
! for every statement form).  One genuine representation gap: the
! parser emits IDENTICAL dicts for SpriteStmt and ParticlesStmt;
! they are told apart by the particle-only props (count / life /
! speed / spread / gravity / seed), which sprite props can never
! contain.  A particles line carrying none of those props is
! indistinguishable from a sprite in dyn form (Python: particles).
!
! Spans: the parser stores span=None everywhere (dyn_null), so every
! diagnostic here is span-less, exactly like the oracle on parser
! input.  Python _span() also falls back to a node's "pos" attribute
! (a vec3), which makes errors.py format_text() CRASH (the oracle
! exits 70/E9000) whenever a diagnostic lands on a node that carries
! a pos; that crash is a Python bug, not behaviour to replicate, so
! node_span() only honours a real span dict {source, line, col,
! length} and otherwise reports no span.
!
! ---------------------------------------------------------------------
! EXTENSION DISPATCH POINTS: validate.py calls the ext_* modules at
! the sites marked "DISPATCH(ext_*)" below.  The core validate.py
! logic around every call is implemented in full; the ext call
! itself is a stub (subroutine dispatch_*) that the extension batch
! replaces with the real f3dc_ext_* port.  Deferred ext checks:
!   ext_geometry.estimate_triangles      (E820 triangle budget)
!   ext_geometry.normalize_geometry      (Wave D IR folding)
!   ext_geometry.validate_geometry       (E301 messages, Wave D)
!   ext_lights_env.extract_light_ext     (point/spot payload)
!   ext_lights_env.validate_light_ext    (E302 messages, point/spot)
!   ext_lights_env.extract_env           (scene env payload)
!   ext_lights_env.validate_env          (E302 messages, scene env)
!   ext_materials.apply_to_ir_object     (material/texture payload)
!   ext_materials.validate_material_ext  (E501/E301 messages)
!   ext_gltf.load_gltf                   (glTF -> tris conversion)
!   ext_sprites_text.extract_sprite / validate_sprite   (E301)
!   ext_sprites_text.extract_text / validate_text       (E301)
!   ext_particles.extract_particles / validate_particles (E301)
!   ext_keys.build_tracks / validate_tracks             (E201)
!   ext_cameras.extract_camera / validate_camera        (E302)
!   ext_post.extract_post / validate_post               (E301)
!   ext_shader.tokenize_expr / to_rpn / validate_shader (E301)
!   ext_skin.extract_bone / validate_bone               (E301)
!   ext_skin.extract_morph / validate_morph             (E301)
!   ext_skin.extract_skin / validate_skin               (E301)
! ---------------------------------------------------------------------
module f3dc_validate
  use, intrinsic :: iso_fortran_env, only: int64, real64
  use, intrinsic :: ieee_arithmetic, only: ieee_is_finite, &
       ieee_value, ieee_quiet_nan, ieee_positive_inf
  use f3dc_dyn, only: dyn, dyn_null, dyn_bool, dyn_int, dyn_real, &
       dyn_str, dyn_list, dyn_dict, dyn_copy, dyn_assign, &
       dyn_list_push, dyn_list_len, dyn_list_at, dyn_dict_get, &
       dyn_dict_set, dyn_dict_has, dyn_dict_len, dyn_dict_key_at, &
       dyn_dict_value_at, DYN_K_NULL, DYN_K_BOOL, DYN_K_INT, &
       DYN_K_REAL, DYN_K_STR, DYN_K_LIST, DYN_K_DICT
  use f3dc_errors, only: error_bag_t, span_t, make_span, &
       make_diagnostic, make_diagnostic_span, error_bag_add, &
       error_bag_has_errors, error_bag_error_count
  use f3dc_str, only: fmt_int, fmt_real, to_lower, char_list, &
       char_list_len, char_list_at, char_list_clear
  use f3dc_desugar, only: desugar
  use f3dc_ir, only: ir_parse_color
  use f3dc_ext_materials, only: mat_apply => apply_to_ir_object, &
       mat_validate => validate_material_ext
  use f3dc_ext_geometry, only: eg_estimate => estimate_triangles, &
       eg_normalize => normalize_geometry, &
       eg_validate => validate_geometry
  use f3dc_ext_lights_env, only: extract_light_ext, &
       validate_light_ext, extract_env, validate_env
  use f3dc_ext_sprites_text, only: extract_sprite, &
       validate_sprite, extract_text, validate_text
  use f3dc_ext_particles, only: extract_particles, &
       validate_particles
  use f3dc_ext_keys, only: build_tracks, validate_tracks
  use f3dc_ext_skin, only: extract_bone, validate_bone, &
       extract_morph, validate_morph, extract_skin, validate_skin
  use f3dc_ext_cameras, only: extract_camera, validate_camera
  use f3dc_ext_post, only: extract_post, validate_post
  use f3dc_ext_shader, only: shader_compile
  use f3dc_ext_gltf, only: load_gltf
  implicit none
  private
  public :: validate_program, f3dc_validate_import_deps

  ! v2.0 P5: import record of the most recent validate run
  ! (side channel for the preview watcher; see the accessor below).
  type(dyn) :: last_import_deps

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
  character(16), parameter :: LIGHT_KINDS_V1(4) = [character(16) :: &
       "directional", "ambient", "point", "spot"]
  character(16), parameter :: CONTROLS_KINDS(2) = [character(16) :: &
       "orbit", "none"]
  character(16), parameter :: EASES(8) = [character(16) :: &
       "linear", "smooth", "in", "out", "ease", "ease-in", &
       "ease-out", "ease-in-out"]
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
       C_BONE = 17, C_SKIN = 18, C_KEYS = 19, C_KEY = 20

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
    character(:), allocatable :: acc
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
      acc = "("
      do k = 1, dyn_list_len(val)
        if (k > 1) acc = acc // ", "
        acc = acc // py_repr(dyn_list_at(val, k))
      end do
      if (dyn_list_len(val) == 1) acc = acc // ","
      out = acc // ")"
    case (DYN_K_DICT)
      acc = "{"
      do k = 1, dyn_dict_len(val)
        if (k > 1) acc = acc // ", "
        acc = acc // py_repr(dyn_str(dyn_dict_key_at(val, k))) // &
              ": " // py_repr(dyn_dict_value_at(val, k))
      end do
      out = acc // "}"
    case default
      out = "None"
    end select
  end function py_str

  !> Python repr() of a string: quote choice + escapes.
  function repr_str(s) result(out)
    character(*), intent(in) :: s
    character(:), allocatable :: out, body
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
    body = ""
    do k = 1, len(s)
      c = iachar(s(k:k))
      if (s(k:k) == "\") then
        body = body // "\\"
      else if (s(k:k) == quote) then
        body = body // "\" // quote
      else if (c == 10) then
        body = body // "\n"
      else if (c == 13) then
        body = body // "\r"
      else if (c == 9) then
        body = body // "\t"
      else if (c < 32 .or. c == 127) then
        body = body // "\x" // hex2(c)
      else
        body = body // s(k:k)
      end if
    end do
    out = quote // body // quote
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
      v = ""
      do k = 1, len(t)
        if (t(k:k) == "_") cycle
        if (index("0123456789.+-eE", t(k:k)) == 0) return
        v = v // t(k:k)
      end do
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
    out = ""
    do k = 1, size(words)
      if (k > 1) out = out // ", "
      out = out // trim(words(k))
    end do
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
  ! Triangle estimate (validate.py _estimate_triangles /
  ! _field_from) + .obj face counter (_count_obj_triangles)
  ! ================================================================

  subroutine field_from(props, names, val)
    type(dyn), intent(in) :: props
    character(*), intent(in) :: names(:)
    type(dyn), intent(out) :: val
    call vget(props, names, val)
  end subroutine field_from

  function estimate_triangles(prim, props) result(total)
    character(*), intent(in) :: prim
    type(dyn), intent(in) :: props
    integer(int64) :: total
    type(dyn) :: v
    integer(int64) :: segments, rings, sides, cnt
    logical :: has_s, has_r, has_detail
    character(:), allocatable :: detail
    logical :: capped
    total = 0_int64
    if (in_words(prim, GEOM_PRIMS)) then
      ! DISPATCH(ext_geometry): estimate_triangles(prim, props)
      ! replaces this 0 when f3dc_ext_geometry lands.
      total = dispatch_ext_geometry_estimate(prim, props)
      return
    end if
    call field_from(props, [character(16) :: "segments"], v)
    call get_int(v, segments, has_s)
    if (.not. has_s) segments = 0_int64
    call field_from(props, [character(16) :: "rings", &
                            "height_segments", "height_segs"], v)
    call get_int(v, rings, has_r)
    if (.not. has_r) rings = 0_int64
    v = dyn_dict_get(props, "detail")
    has_detail = v%kind == DYN_K_STR
    if (has_detail) then
      detail = to_lower(v%s)
      block
        integer(int64) :: ps, pr
        logical :: found
        call detail_preset(prim == "torus", detail, ps, pr, found)
        if (found) then
          if (.not. has_s) then
            segments = ps
            has_s = .true.
          end if
          if (.not. has_r) then
            rings = pr
            has_r = .true.
          end if
        end if
      end block
    end if
    ! capped = not props.get("open") and props.get("capped", True)
    ! is not False   (identity check against the False singleton)
    capped = .not. py_truthy(dyn_dict_get(props, "open"))
    v = dyn_dict_get(props, "capped")
    if (v%kind == DYN_K_BOOL .and. .not. v%b) capped = .false.
    select case (prim)
    case ("cube")
      total = 12_int64
    case ("sphere")
      if (.not. has_s .or. segments == 0_int64) segments = 16_int64
      if (.not. has_r .or. rings == 0_int64) rings = 12_int64
      total = 2_int64 * segments * max(rings - 1_int64, 1_int64)
    case ("cylinder")
      if (.not. has_s .or. segments == 0_int64) segments = 16_int64
      if (.not. has_r .or. rings == 0_int64) rings = 1_int64
      total = 2_int64 * segments * rings
      if (capped) total = total + 2_int64 * segments
    case ("cone")
      if (.not. has_s .or. segments == 0_int64) segments = 16_int64
      if (.not. has_r .or. rings == 0_int64) rings = 1_int64
      total = segments * (2_int64 * rings - 1_int64)
      if (capped) total = total + segments
    case ("plane")
      if (.not. has_s .or. segments == 0_int64) segments = 1_int64
      call get_int(dyn_dict_get(props, "depth_segments"), cnt, has_s)
      if (.not. has_s .or. cnt == 0_int64) cnt = segments
      total = 4_int64 * segments * cnt
    case ("pyramid")
      call get_int(dyn_dict_get(props, "sides"), sides, has_s)
      if (.not. has_s .or. sides == 0_int64) sides = 4_int64
      total = max(2_int64 * sides - 2_int64, 0_int64)
    case ("torus")
      if (.not. has_s .or. segments == 0_int64) segments = 16_int64
      if (.not. has_r .or. rings == 0_int64) rings = 12_int64
      total = 2_int64 * segments * rings
    case ("tris")
      v = dyn_dict_get(props, "tris")
      if (.not. py_truthy(v)) v = dyn_dict_get(props, "triangles")
      if (v%kind == DYN_K_LIST) then
        total = int(dyn_list_len(v), int64)
        return
      end if
      ! Python: _int(props.get("tri_count", props.get("count"))) --
      ! the default only applies when the key is absent entirely.
      if (dyn_dict_has(props, "tri_count")) then
        v = dyn_dict_get(props, "tri_count")
      else
        v = dyn_dict_get(props, "count")
      end if
      call get_int(v, cnt, has_s)
      if (has_s) total = cnt
    case ("load")
      call get_int(dyn_dict_get(props, "_load_tris"), cnt, has_s)
      if (has_s) total = cnt
    end select
  end function estimate_triangles

  !> Detail presets -> (segments, rings): validate._DETAIL /
  !! _DETAIL_TORUS.
  subroutine detail_preset(is_torus, detail, ps, pr, found)
    logical, intent(in) :: is_torus
    character(*), intent(in) :: detail
    integer(int64), intent(out) :: ps, pr
    logical, intent(out) :: found
    found = .true.
    ps = 0_int64
    pr = 0_int64
    if (is_torus) then
      select case (detail)
      case ("low")
        ps = 10_int64; pr = 8_int64
      case ("med", "medium")
        ps = 16_int64; pr = 12_int64
      case ("high")
        ps = 32_int64; pr = 24_int64
      case default
        found = .false.
      end select
    else
      select case (detail)
      case ("low")
        ps = 8_int64; pr = 6_int64
      case ("med", "medium")
        ps = 16_int64; pr = 12_int64
      case ("high")
        ps = 32_int64; pr = 24_int64
      case default
        found = .false.
      end select
    end if
  end subroutine detail_preset

  !> validate._count_obj_triangles: face count for a loaded .obj
  !! (lines starting with 'f '; each contributes max(words-3, 1)).
  function count_obj_triangles(path) result(total)
    character(*), intent(in) :: path
    integer(int64) :: total
    integer :: unit, ios, words, k
    character(65536) :: line
    logical :: in_word
    total = 0_int64
    open (newunit=unit, file=path, status="old", action="read", &
          iostat=ios)
    if (ios /= 0) return
    do
      read (unit, "(A)", iostat=ios) line
      if (ios /= 0) exit
      if (len_trim(line) >= 2 .and. line(1:2) == "f ") then
        words = 0
        in_word = .false.
        do k = 1, len_trim(line)
          if (is_ws(line(k:k))) then
            in_word = .false.
          else if (.not. in_word) then
            in_word = .true.
            words = words + 1
          end if
        end do
        total = total + int(max(words - 3, 1), int64)
      end if
    end do
    close (unit)
  end function count_obj_triangles

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


  ! ================================================================
  ! Extension dispatch points (see the header list).  Each stub is
  ! the exact call site of the Python ext_* function named; the
  ! extension batch replaces the stub body with the real port.
  ! Until then the stub contributes no diagnostics and no payload,
  ! which matches the Python oracle on every input the ext check
  ! accepts silently.
  ! ================================================================

  !> DISPATCH(ext_geometry): ext_geometry.estimate_triangles.
  function dispatch_ext_geometry_estimate(prim, props) result(n)
    character(*), intent(in) :: prim
    type(dyn), intent(in) :: props
    integer(int64) :: n
    n = eg_estimate(prim, props)
    if (len(prim) < 0) continue  ! silence warnings
  end function dispatch_ext_geometry_estimate

  !> DISPATCH(ext_geometry): normalize_geometry + validate_geometry
  !! (E301 messages + IR folding of radius/size/height/segments).
  subroutine dispatch_ext_geometry(prim, props, node, geom, &
      radius, has_radius, size, has_size, obj_height, has_height, &
      segments, has_segments)
    character(*), intent(in) :: prim
    type(dyn), intent(in) :: props, node
    type(dyn), intent(out) :: geom
    real(real64), intent(inout) :: radius, size, obj_height
    logical, intent(inout) :: has_radius, has_size, has_height, &
         has_segments
    integer(int64), intent(inout) :: segments
    type(char_list) :: codes, messages
    type(dyn) :: v
    integer :: k
    geom = eg_normalize(prim, props)
    call eg_validate(prim, props, geom, codes, messages)
    do k = 1, char_list_len(codes)
      call verrn(char_list_at(codes, k), &
                 char_list_at(messages, k), node)
    end do
    call char_list_clear(codes); call char_list_clear(messages)
    v = dyn_dict_get(geom, "radius")
    if (v%kind /= DYN_K_NULL) call get_num(v, radius, has_radius)
    if (prim == "ring") then
      v = dyn_dict_get(geom, "inner")
      call get_num(v, size, has_size)
    end if
    if (prim == "torusknot") then
      v = dyn_dict_get(geom, "tube")
      call get_num(v, size, has_size)
    end if
    if (prim == "capsule" .or. prim == "extrude") then
      v = dyn_dict_get(geom, "height")
      call get_num(v, obj_height, has_height)
    end if
    v = dyn_dict_get(geom, "segments")
    if (v%kind /= DYN_K_NULL) &
      call get_int(v, segments, has_segments)
  end subroutine dispatch_ext_geometry

  !> DISPATCH(ext_gltf): load_gltf(full) -> 'tris' IR object
  !! (validate.py's glTF branch of the load loop: E501 on load
  !! failure; name / material / transform handling; total_tris).
  subroutine dispatch_ext_gltf(node, lpath, full)
    type(dyn), intent(in) :: node
    character(*), intent(in) :: lpath, full
    type(dyn) :: props, v, gdata, countv, ir_obj, exts
    type(dyn) :: gscale_raw
    character(:), allocatable :: gname, gmaterial, errmsg
    logical :: ok, has_gscale_vec, has_gscale_num
    real(real64) :: gpos(3), grot(3), gscale3(3), gscale_vec(3)
    real(real64) :: gscale_num

    call load_gltf(full, gdata, ok, errmsg)
    if (.not. ok) then
      call verrn("E501", "could not load glTF " // &
           repr_str(lpath) // ": " // errmsg, node)
      return
    end if
    props = props_of(node)
    call vfield(node, props, [character(12) :: "name", "id"], v)
    if (v%kind == DYN_K_STR .and. len(v%s) > 0) then
      gname = v%s
    else
      gname = "gltf" // istr(int(dyn_list_len(vs%ir_objects), &
           int64) + 1_int64)
    end if
    if (dyn_dict_has(vs%names, gname)) then
      call verrn("E201", "there are two objects called " // &
           repr_str(gname) // &
           "; give each object its own name", node)
      return
    end if
    call vfield(node, props, [character(12) :: "material"], v)
    if (v%kind /= DYN_K_NULL) then
      gmaterial = to_lower(py_str(v))
      if (.not. in_words(gmaterial, MATERIALS)) then
        call verrn("E205", "material " // repr_str(gmaterial) // &
             " is not built yet", node)
        gmaterial = "lambert"
      end if
    else
      gmaterial = "lambert"
    end if
    call vfield(node, props, [character(12) :: "at", "pos", &
                             "position"], v)
    call vec3_or(v, [0.0_real64, 0.0_real64, 0.0_real64], gpos)
    call vfield(node, props, [character(12) :: "rotate", &
                             "rotation", "rot"], v)
    call vec3_or(v, [0.0_real64, 0.0_real64, 0.0_real64], grot)
    call vfield(node, props, [character(12) :: "scale"], gscale_raw)
    call get_vec3(gscale_raw, gscale_vec, has_gscale_vec)
    call get_num(gscale_raw, gscale_num, has_gscale_num)
    if (has_gscale_vec) then
      gscale3 = gscale_vec
    else if (has_gscale_num) then
      gscale3 = [gscale_num, gscale_num, gscale_num]
    else
      gscale3 = [1.0_real64, 1.0_real64, 1.0_real64]
    end if
    call dyn_dict_set(vs%names, gname, node)
    countv = dyn_dict_get(gdata, "count")
    vs%total_tris = vs%total_tris + countv%i
    ir_obj = dyn_dict()
    call dyn_dict_set(ir_obj, "name", dyn_str(gname))
    call dyn_dict_set(ir_obj, "prim", dyn_str("tris"))
    call dyn_dict_set(ir_obj, "color", dyn_null())
    call dyn_dict_set(ir_obj, "pos", vec3_dyn(gpos))
    call dyn_dict_set(ir_obj, "rotate", vec3_dyn(grot))
    call dyn_dict_set(ir_obj, "scale", vec3_dyn(gscale3))
    call dyn_dict_set(ir_obj, "size", dyn_null())
    call dyn_dict_set(ir_obj, "size3", dyn_null())
    call dyn_dict_set(ir_obj, "radius", dyn_null())
    call dyn_dict_set(ir_obj, "height", dyn_null())
    call dyn_dict_set(ir_obj, "segments", dyn_null())
    call dyn_dict_set(ir_obj, "detail", dyn_str("med"))
    call dyn_dict_set(ir_obj, "capped", dyn_bool(.true.))
    call dyn_dict_set(ir_obj, "material", dyn_str(gmaterial))
    call dyn_dict_set(ir_obj, "triangles", &
         dyn_dict_get(gdata, "triangles"))
    call dyn_dict_set(ir_obj, "source_file", dyn_str(lpath))
    exts = dyn_dict()
    call dyn_dict_set(ir_obj, "extensions", exts)
    call dyn_list_push(vs%ir_objects, ir_obj)
    vs%last_obj_name = gname
    vs%has_last_obj = .true.
  end subroutine dispatch_ext_gltf

  !> DISPATCH(ext_lights_env): extract_light_ext +
  !! validate_light_ext (E302 messages for point/spot lights).
  subroutine dispatch_ext_light(kind, ext_in, node)
    character(*), intent(in) :: kind
    type(dyn), intent(inout) :: ext_in
    type(dyn), intent(in) :: node
    type(dyn) :: ext
    type(char_list) :: msgs
    integer :: j
    call extract_light_ext(ext_in, ext)
    call validate_light_ext(kind, ext, msgs)
    do j = 1, char_list_len(msgs)
      call verrn("E302", char_list_at(msgs, j), node)
    end do
    call dyn_assign(ext_in, ext)
  end subroutine dispatch_ext_light

  !> DISPATCH(ext_lights_env): extract_env + validate_env
  !! (E302 messages for scene fog/tonemap/shadow clauses).
  subroutine dispatch_ext_env(env_in)
    type(dyn), intent(in) :: env_in
    type(dyn) :: env
    type(char_list) :: msgs
    integer :: j
    call extract_env(env_in, env)
    call validate_env(env, msgs)
    do j = 1, char_list_len(msgs)
      call verr("E302", char_list_at(msgs, j))
    end do
    call set_scene_extension("env", env)
  end subroutine dispatch_ext_env

  !> DISPATCH(ext_materials): apply_to_ir_object +
  !! validate_material_ext (E501 for texture messages, else E301).
  subroutine dispatch_ext_materials(ir_obj, raw_props, material, node)
    type(dyn), intent(inout) :: ir_obj
    type(dyn), intent(in) :: raw_props, node
    character(*), intent(in) :: material
    type(dyn) :: raw, exts, extd, tex
    type(char_list) :: msgs
    character(:), allocatable :: cand, t
    integer :: k, a, b
    raw = dyn_copy(raw_props)
    call dyn_dict_set(raw, "material", dyn_str(material))
    tex = dyn_dict_get(raw, "texture")
    if (tex%kind == DYN_K_STR .and. allocated(tex%s)) then
      t = tex%s
      if (len(t) > 0) then
       if (t(1:1) /= "/") then
        a = 1; b = len(t)
        do while (a <= b)
          if (t(a:a) /= '"' .and. t(a:a) /= "'") exit
          a = a + 1
        end do
        do while (b >= a)
          if (t(b:b) /= '"' .and. t(b:b) /= "'") exit
          b = b - 1
        end do
        if (a > b) then
          cand = ""
        else
          cand = join_path(vs%base_dir, t(a:b))
        end if
        if (len(cand) > 0 .and. path_is_file(cand)) &
          call dyn_dict_set(raw, "texture", dyn_str(cand))
       end if
      end if
    end if
    ! v3.0 Phase 4: the four extra texture-slot paths resolve
    ! exactly like "texture" above (relative paths are made
    ! source-relative when the file exists there).
    block
      character(len=12) :: slot_keys(4)
      integer :: sk
      slot_keys = [character(len=12) :: "normalmap", "mr", &
                   "emissivemap", "occlusionmap"]
      do sk = 1, 4
        tex = dyn_dict_get(raw, trim(slot_keys(sk)))
        if (tex%kind == DYN_K_STR .and. allocated(tex%s)) then
          t = tex%s
          if (len(t) > 0) then
           if (t(1:1) /= "/") then
            a = 1; b = len(t)
            do while (a <= b)
              if (t(a:a) /= '"' .and. t(a:a) /= "'") exit
              a = a + 1
            end do
            do while (b >= a)
              if (t(b:b) /= '"' .and. t(b:b) /= "'") exit
              b = b - 1
            end do
            if (a > b) then
              cand = ""
            else
              cand = join_path(vs%base_dir, t(a:b))
            end if
            if (len(cand) > 0 .and. path_is_file(cand)) &
              call dyn_dict_set(raw, trim(slot_keys(sk)), &
                                dyn_str(cand))
           end if
          end if
        end if
      end do
    end block
    exts = dyn_dict_get(ir_obj, "extensions")
    if (exts%kind /= DYN_K_DICT) exts = dyn_dict()
    call dyn_dict_set(exts, "raw_props", raw)
    call dyn_dict_set(ir_obj, "extensions", exts)
    call mat_apply(ir_obj)
    exts = dyn_dict_get(ir_obj, "extensions")
    extd = dyn_dict_get(exts, "material")
    if (extd%kind == DYN_K_DICT) then
      call mat_validate(material, extd, msgs)
      do k = 1, char_list_len(msgs)
        if (index(char_list_at(msgs, k), "texture") > 0) then
          call verrn("E501", char_list_at(msgs, k), node)
        else
          call verrn("E301", char_list_at(msgs, k), node)
        end if
      end do
    end if
  end subroutine dispatch_ext_materials

  !> DISPATCH(ext_sprites_text): extract_sprite + validate_sprite
  !! (E301 messages); the normalised payload is IR-only.
  subroutine dispatch_ext_sprite(ext_in, node, ext)
    type(dyn), intent(in) :: ext_in, node
    type(dyn), intent(out) :: ext
    type(char_list) :: msgs
    integer :: mi
    call extract_sprite(ext_in, ext)
    call validate_sprite(ext, msgs)
    do mi = 1, char_list_len(msgs)
      call verrn("E301", char_list_at(msgs, mi), node)
    end do
  end subroutine dispatch_ext_sprite

  !> DISPATCH(ext_sprites_text): extract_text + validate_text (E301).
  subroutine dispatch_ext_text(ext_in, node, ext)
    type(dyn), intent(in) :: ext_in, node
    type(dyn), intent(out) :: ext
    type(char_list) :: msgs
    integer :: mi
    call extract_text(ext_in, ext)
    call validate_text(ext, msgs)
    do mi = 1, char_list_len(msgs)
      call verrn("E301", char_list_at(msgs, mi), node)
    end do
  end subroutine dispatch_ext_text

  !> DISPATCH(ext_particles): extract_particles +
  !! validate_particles (E301 messages).
  subroutine dispatch_ext_particles(ext_in, node)
    type(dyn), intent(inout) :: ext_in
    type(dyn), intent(in) :: node
    type(dyn) :: ext
    type(char_list) :: msgs
    integer :: k
    call extract_particles(ext_in, ext)
    call validate_particles(ext, msgs)
    do k = 1, char_list_len(msgs)
      call verrn("E301", char_list_at(msgs, k), node)
    end do
    call char_list_clear(msgs)
    call dyn_assign(ext_in, ext)
  end subroutine dispatch_ext_particles

  !> DISPATCH(ext_keys): build_tracks + validate_tracks (E201
  !! messages, span-less in Python).
  subroutine dispatch_ext_keys(headers, raw_keys, tracks)
    type(dyn), intent(in) :: headers, raw_keys
    type(dyn), intent(out) :: tracks
    type(char_list) :: errs
    integer :: i
    call build_tracks(headers, raw_keys, tracks)
    errs = char_list()
    call validate_tracks(tracks, errs)
    do i = 1, char_list_len(errs)
      call verr("E201", char_list_at(errs, i))
    end do
  end subroutine dispatch_ext_keys

  !> DISPATCH(ext_cameras): extract_camera + validate_camera
  !! (E302 messages for ortho cameras).
  subroutine dispatch_ext_camera(ext_in, node, wavec)
    type(dyn), intent(in) :: ext_in, node
    type(dyn), intent(inout) :: wavec
    type(dyn) :: ext, tv
    type(char_list) :: msgs
    integer :: k
    call extract_camera(ext_in, ext)
    call validate_camera(ext, msgs)
    do k = 1, char_list_len(msgs)
      call verrn("E302", char_list_at(msgs, k), node)
    end do
    tv = dyn_dict_get(ext, "type")
    if (tv%kind == DYN_K_STR .and. tv%s == "ortho") &
      call dyn_dict_set(wavec, "camera", ext)
  end subroutine dispatch_ext_camera

  !> DISPATCH(ext_post): extract_post + validate_post (E301).
  subroutine dispatch_ext_post(ext_in, node, chain)
    type(dyn), intent(in) :: ext_in, node
    type(dyn), intent(inout) :: chain
    type(dyn) :: ext
    type(char_list) :: msgs
    integer :: k
    call extract_post(ext_in, ext)
    call validate_post(ext, msgs)
    do k = 1, char_list_len(msgs)
      call verrn("E301", char_list_at(msgs, k), node)
    end do
    call dyn_list_push(chain, ext)
  end subroutine dispatch_ext_post

  !> DISPATCH(ext_shader): tokenize_expr + to_rpn + validate_shader
  !! (E301 messages).  ok=.false. mirrors a ValueError from to_rpn.
  subroutine dispatch_ext_shader_rpn(name, expr, node, rpn, msgs, ok)
    character(*), intent(in) :: name, expr
    type(dyn), intent(in) :: node
    type(dyn), intent(out) :: rpn
    type(char_list), intent(inout) :: msgs
    logical, intent(out) :: ok
    if (node%kind < 0) continue
    call shader_compile(name, expr, rpn, msgs, ok)
  end subroutine dispatch_ext_shader_rpn

  !> DISPATCH(ext_skin): extract_bone + validate_bone (E301).
  subroutine dispatch_ext_bone(ext_in, node, bone_names, bone_name, &
                               has_name)
    type(dyn), intent(inout) :: ext_in
    type(dyn), intent(in) :: node, bone_names
    character(:), allocatable, intent(out) :: bone_name
    logical, intent(out) :: has_name
    type(dyn) :: ext, known, v
    type(char_list) :: errs
    integer :: i
    call extract_bone(ext_in, ext)
    known = dyn_list()
    do i = 1, dyn_dict_len(bone_names)
      call dyn_list_push(known, &
           dyn_str(dyn_dict_key_at(bone_names, i)))
    end do
    errs = char_list()
    call validate_bone(ext, known, errs)
    do i = 1, char_list_len(errs)
      call verrn("E301", char_list_at(errs, i), node)
    end do
    call dyn_assign(ext_in, ext)
    v = dyn_dict_get(ext, "name")
    has_name = v%kind == DYN_K_STR .and. len(v%s) > 0
    bone_name = ""
    if (has_name) bone_name = v%s
  end subroutine dispatch_ext_bone

  !> DISPATCH(ext_skin): extract_morph + validate_morph (E301).
  !! target_out mirrors extract_morph's "target" (the statement's
  !! target/name field) for validate.py's core E201 check.
  subroutine dispatch_ext_morph(ext_in, node, target_out, has_target)
    type(dyn), intent(inout) :: ext_in
    type(dyn), intent(in) :: node
    character(:), allocatable, intent(out) :: target_out
    logical, intent(out) :: has_target
    type(dyn) :: ext, v
    type(char_list) :: errs
    integer :: i
    call extract_morph(ext_in, ext)
    errs = char_list()
    call validate_morph(ext, errs)
    do i = 1, char_list_len(errs)
      call verrn("E301", char_list_at(errs, i), node)
    end do
    call dyn_assign(ext_in, ext)
    v = dyn_dict_get(ext, "target")
    has_target = v%kind == DYN_K_STR .and. len(v%s) > 0
    target_out = ""
    if (has_target) target_out = v%s
  end subroutine dispatch_ext_morph

  !> DISPATCH(ext_skin): extract_skin + validate_skin (E301).
  !! target_out mirrors extract_skin's "target" as above.
  subroutine dispatch_ext_skin(ext_in, node, bone_names, target_out, &
                               has_target)
    type(dyn), intent(inout) :: ext_in
    type(dyn), intent(in) :: node, bone_names
    character(:), allocatable, intent(out) :: target_out
    logical, intent(out) :: has_target
    type(dyn) :: ext, known, v
    type(char_list) :: errs
    integer :: i
    call extract_skin(ext_in, ext)
    known = dyn_list()
    do i = 1, dyn_dict_len(bone_names)
      call dyn_list_push(known, &
           dyn_str(dyn_dict_key_at(bone_names, i)))
    end do
    errs = char_list()
    call validate_skin(ext, known, errs)
    do i = 1, char_list_len(errs)
      call verrn("E301", char_list_at(errs, i), node)
    end do
    call dyn_assign(ext_in, ext)
    v = dyn_dict_get(ext, "target")
    has_target = v%kind == DYN_K_STR .and. len(v%s) > 0
    target_out = ""
    if (has_target) target_out = v%s
  end subroutine dispatch_ext_skin

  ! ================================================================
  ! The walk (validate.py: walk / walk_scene closures)
  ! ================================================================

  recursive subroutine walk_nodes(nodes)
    type(dyn), intent(in) :: nodes
    type(dyn) :: node
    integer :: k, cat
    do k = 1, dyn_list_len(nodes)
      node = dyn_list_at(nodes, k)
      call classify_node(node, cat)
      select case (cat)
      case (C_GROUP)
        call walk_nodes(children_of(node))
      case (C_SCENE)
        if (vs%has_scene) then
          call verrn("E401", "there are two scene lines; " // &
               "keep only one", node)
        end if
        vs%has_scene = .true.
        call walk_scene(node)
      case (C_CAMERA)
        if (vs%has_camera) then
          call verrn("E401", "there are two camera lines; " // &
               "keep only one", node)
        end if
        vs%has_camera = .true.
        vs%camera_node = dyn_copy(node)
      case (C_LIGHT)
        call dyn_list_push(vs%light_nodes, node)
      case (C_CONTROLS)
        vs%has_controls = .true.
        vs%controls_node = dyn_copy(node)
      case (C_LOAD)
        call dyn_list_push(vs%load_nodes, node)
      case (C_SPRITE)
        call dyn_list_push(vs%sprite_nodes, node)
      case (C_TEXT)
        call dyn_list_push(vs%text_nodes, node)
      case (C_PARTICLES)
        call dyn_list_push(vs%particles_nodes, node)
      case (C_FILTER)
        call dyn_list_push(vs%filter_nodes, node)
      case (C_INSTANCE)
        call dyn_list_push(vs%instance_nodes, node)
      case (C_SHADERDEF)
        call dyn_list_push(vs%shader_nodes, node)
      case (C_MORPH)
        call dyn_list_push(vs%morph_nodes, node)
      case (C_BONE)
        call dyn_list_push(vs%bone_nodes, node)
      case (C_SKIN)
        call dyn_list_push(vs%skin_nodes, node)
      case (C_KEYS)
        call dyn_list_push(vs%keys_header_nodes, node)
      case (C_KEY)
        call dyn_list_push(vs%key_nodes, node)
      case (C_ANIM)
        call dyn_list_push(vs%anim_nodes, node)
      case (C_OUTPUT)
        call dyn_list_push(vs%output_nodes, node)
      case (C_OBJECT)
        call dyn_list_push(vs%object_nodes, node)
      end select
      ! Unknown statements: parser/desugar own their codes.
    end do
  end subroutine walk_nodes

  subroutine walk_scene(node)
    type(dyn), intent(in) :: node
    type(dyn) :: props, v, sizev
    integer :: k
    character(12) :: env_keys(4)
    integer(int64) :: w, h
    logical :: has_w, has_h
    integer :: rgb(3)
    logical :: has_rgb
    props = props_of(node)
    env_keys = [character(12) :: "fog", "tonemap", "shadow", &
                "antialias"]
    do k = 1, 4
      call vfield(node, props, [character(12) :: env_keys(k)], v)
      if (v%kind /= DYN_K_NULL) then
        call dyn_dict_set(vs%env_props, trim(env_keys(k)), v)
      end if
    end do
    call vfield(node, props, [character(12) :: "name", "title"], v)
    if (v%kind == DYN_K_STR .and. len(v%s) > 0) vs%scene_name = v%s
    call vfield(node, props, [character(12) :: "shading"], v)
    if (v%kind == DYN_K_STR) then
      if (to_lower(v%s) == "smooth" .or. to_lower(v%s) == "flat") then
        vs%scene_shading = to_lower(v%s)
        vs%has_scene_shading = .true.
      end if
    end if
    call vfield(node, props, [character(12) :: "width", "w"], v)
    call get_int(v, w, has_w)
    call vfield(node, props, [character(12) :: "height", "h"], v)
    call get_int(v, h, has_h)
    call vfield(node, props, [character(12) :: "size", &
                              "dimensions"], sizev)
    if (sizev%kind == DYN_K_LIST .and. dyn_list_len(sizev) >= 2) then
      block
        integer(int64) :: sw, sh
        logical :: okw, okh
        call get_int(dyn_list_at(sizev, 1), sw, okw)
        if (okw) then
          w = sw
          has_w = .true.
        end if
        call get_int(dyn_list_at(sizev, 2), sh, okh)
        if (okh) then
          h = sh
          has_h = .true.
        end if
      end block
    end if
    if (has_w) vs%width = w
    if (has_h) vs%height = h
    call vfield(node, props, [character(12) :: "bg", "background", &
                              "color", "colour"], v)
    if (v%kind /= DYN_K_NULL) then
      call parse_color_val(v, node, rgb, has_rgb)
      if (has_rgb) vs%bg = rgb
    end if
    call walk_nodes(children_of(node))
  end subroutine walk_scene


  ! ================================================================
  ! Objects (validate.py: add_object closure)
  ! ================================================================

  subroutine add_object(node, forced_prim, has_forced, load_path, &
                        has_load)
    type(dyn), intent(in) :: node
    character(*), intent(in) :: forced_prim, load_path
    logical, intent(in) :: has_forced, has_load
    type(dyn) :: props, v, ir_obj, exts, tri_props
    character(:), allocatable :: prim, name, material, detail
    character(:), allocatable :: shading_emit, prim_shading_default
    logical :: has_shading_emit, shading_ok
    character(:), allocatable :: mirror_emit
    logical :: has_mirror_emit
    integer :: rgb(3)
    logical :: has_rgb, has_mat
    real(real64) :: size, radius, obj_height, tube, width_v, depth_v
    logical :: has_size, has_radius, has_height, has_tube, has_wv, &
         has_dv
    type(dyn) :: size_raw
    real(real64) :: size3(3)
    logical :: has_size3
    integer(int64) :: segments, rings, sides
    logical :: has_segments, has_rings, has_sides
    real(real64) :: position(3), rotation(3)
    type(dyn) :: scale_raw
    real(real64) :: scale_vec(3), scale_num, scale3(3)
    logical :: has_scale_vec, has_scale_num
    logical :: capped
    integer(int64) :: tris_est
    type(dyn) :: raw_tris, cand
    type(dyn) :: geom_payload
    logical :: has_geom_payload
    integer :: k
    character(16) :: mat_keys(4)
    ! v3.0 Phase 4 material keys (dispatch gate only, mirroring
    ! mat_keys): any of these present also routes the object
    ! through dispatch_ext_materials.
    character(16) :: p4_keys(8) = [character(16) :: "normalmap", &
      "mr", "emissivemap", "occlusionmap", "emissive", "opacity", &
      "alpha", "cutoff"]

    props = props_of(node)
    if (has_forced) then
      prim = forced_prim
    else
      call vfield(node, props, [character(12) :: "prim", &
           "primitive", "kind", "type"], v)
      if (v%kind == DYN_K_NULL) then
        prim = "cube"
      else
        prim = to_lower(py_str(v))
      end if
    end if
    call vfield(node, props, [character(12) :: "name", "id"], v)
    if (v%kind == DYN_K_STR .and. len(v%s) > 0) then
      name = v%s
    else
      name = ""
    end if
    if (.not. in_words(prim, PRIMITIVES) .and. prim /= "load") then
      call verrn("E205", repr_str(prim) // &
           " is not built yet; v1 primitives are: " // &
           join_words(PRIMITIVES), node)
      return
    end if
    if (len(name) == 0) then
      name = prim // istr(int(dyn_list_len(vs%ir_objects), int64) &
           + 1_int64)
    end if
    if (dyn_dict_has(vs%names, name)) then
      call verrn("E201", "there are two objects called " // &
           repr_str(name) // &
           "; give each object its own name", node)
      return
    end if
    call dyn_dict_set(vs%names, name, node)
    ! Material (Wave A textures are real via ext_materials; the
    ! payload attach is a dispatch point in the Wave A block below).
    call vfield(node, props, [character(12) :: "material"], v)
    has_mat = v%kind /= DYN_K_NULL
    if (has_mat) then
      material = to_lower(py_str(v))
      if (.not. in_words(material, MATERIALS)) then
        call verrn("E205", "material " // repr_str(material) // &
             " is not built yet; v1 materials are: " // &
             join_words(MATERIALS), node)
        material = "lambert"
      end if
    else
      material = "lambert"
    end if
    call vfield(node, props, [character(12) :: "color", "colour", &
         "color_value", "colour_value", "color_raw"], v)
    if (v%kind /= DYN_K_NULL) then
      call parse_color_val(v, node, rgb, has_rgb)
      if (.not. has_rgb) rgb = [255, 255, 255]
    else
      has_rgb = .false.
      rgb = 0
    end if
    ! Dimensions, with the per-prim defaults of the B09 brief.
    call vfield(node, props, [character(12) :: "size"], size_raw)
    call get_vec3(size_raw, size3, has_size3)
    call get_num(size_raw, size, has_size)
    if (.not. has_size .and. has_size3) then
      size = size3(1)
      has_size = .true.
    end if
    if (.not. has_size) then
      select case (prim)
      case ("cube")
        size = 2.0_real64
        has_size = .true.
      case ("plane")
        size = 4.0_real64
        has_size = .true.
      case ("pyramid")
        size = 2.0_real64
        has_size = .true.
      end select
    end if
    call vfield(node, props, [character(12) :: "radius"], v)
    call get_num(v, radius, has_radius)
    if (.not. has_radius) then
      select case (prim)
      case ("sphere", "cylinder", "cone")
        radius = 1.0_real64
        has_radius = .true.
      case ("torus")
        radius = 1.5_real64
        has_radius = .true.
      end select
    end if
    call vfield(node, props, [character(12) :: "height"], v)
    call get_num(v, obj_height, has_height)
    if (.not. has_height) then
      select case (prim)
      case ("cylinder", "cone", "pyramid")
        obj_height = 2.0_real64
        has_height = .true.
      end select
    end if
    call check_dim("size", size, has_size, node)
    call check_dim("radius", radius, has_radius, node)
    call check_dim("height", obj_height, has_height, node)
    call vfield(node, props, [character(12) :: "tube"], v)
    call get_num(v, tube, has_tube)
    call check_dim("tube", tube, has_tube, node)
    call vfield(node, props, [character(12) :: "width"], v)
    call get_num(v, width_v, has_wv)
    call vfield(node, props, [character(12) :: "depth"], v)
    call get_num(v, depth_v, has_dv)
    call check_dim("width", width_v, has_wv, node)
    call check_dim("depth", depth_v, has_dv, node)
    call vfield(node, props, [character(12) :: "segments"], v)
    call get_int(v, segments, has_segments)
    if (.not. has_segments) then
      select case (prim)
      case ("sphere", "cylinder", "cone")
        segments = 16_int64
        has_segments = .true.
      case ("torus")
        segments = 24_int64
        has_segments = .true.
      end select
    end if
    has_geom_payload = .false.
    if (in_words(prim, GEOM_PRIMS)) then
      ! DISPATCH(ext_geometry): normalize_geometry folds radius /
      ! size / height / segments for Wave D prims and
      ! validate_geometry reports their E301s, before the segment
      ! range check below.
      call dispatch_ext_geometry(prim, props, node, geom_payload, &
           radius, has_radius, size, has_size, obj_height, &
           has_height, segments, has_segments)
      has_geom_payload = .true.
    end if
    call vfield(node, props, [character(12) :: "detail"], v)
    if (py_truthy(v)) then
      detail = to_lower(py_str(v))
    else
      detail = "med"
    end if
    ! P1 shading resolution.  Primitive default: smooth for the
    ! curved prims, flat for everything else.  The resolved default
    ! is NEVER emitted; the IR carries "shading" only when it was
    ! explicitly determined -- the object's own prop (always), or
    ! the scene-level default expanded onto objects whose primitive
    ! default differs from it.
    select case (prim)
    case ("sphere", "cylinder", "cone", "capsule", "tube", &
          "lathe", "torus", "torusknot")
      prim_shading_default = "smooth"
    case default
      prim_shading_default = "flat"
    end select
    has_shading_emit = .false.
    shading_emit = ""
    call vfield(node, props, [character(12) :: "shading"], v)
    shading_ok = .false.
    if (v%kind == DYN_K_STR) then
      shading_ok = to_lower(v%s) == "smooth" .or. &
                   to_lower(v%s) == "flat"
    end if
    if (shading_ok) then
      shading_emit = to_lower(v%s)
      has_shading_emit = .true.
    else if (vs%has_scene_shading .and. &
             vs%scene_shading /= prim_shading_default) then
      shading_emit = vs%scene_shading
      has_shading_emit = .true.
    end if
    ! P3 mirror resolution: per-object only (no scene-level
    ! default); the prop passes through untouched when present
    ! (parser already restricted it to x|y|z).
    has_mirror_emit = .false.
    mirror_emit = ""
    call vfield(node, props, [character(12) :: "mirror"], v)
    if (v%kind == DYN_K_STR) then
      if (to_lower(v%s) == "x" .or. to_lower(v%s) == "y" .or. &
          to_lower(v%s) == "z") then
        mirror_emit = to_lower(v%s)
        has_mirror_emit = .true.
      end if
    end if
    if (has_segments .and. (segments < MIN_SEGMENTS .or. &
        segments > MAX_SEGMENTS)) then
      call verrn("E301", "segments is " // istr(segments) // &
           ", but it must be " // istr(MIN_SEGMENTS) // " to " // &
           istr(MAX_SEGMENTS), node)
    end if
    call vfield(node, props, [character(12) :: "rings"], v)
    call get_int(v, rings, has_rings)
    if (has_rings .and. (rings < 1_int64 .or. &
        rings > MAX_SEGMENTS)) then
      call verrn("E301", "rings is " // istr(rings) // &
           ", but it must be 1 to " // istr(MAX_SEGMENTS), node)
    end if
    call vfield(node, props, [character(12) :: "sides"], v)
    call get_int(v, sides, has_sides)
    if (has_sides .and. (sides < 3_int64 .or. &
        sides > 64_int64)) then
      call verrn("E301", "sides is " // istr(sides) // &
           ", but a pyramid needs at least 3 sides", node)
    end if
    call vfield(node, props, [character(12) :: "at", "pos", &
                             "position"], v)
    call vec3_or(v, [0.0_real64, 0.0_real64, 0.0_real64], position)
    call vfield(node, props, [character(12) :: "rotate", &
                              "rotation", "rot"], v)
    call vec3_or(v, [0.0_real64, 0.0_real64, 0.0_real64], rotation)
    call vfield(node, props, [character(12) :: "scale"], scale_raw)
    call get_vec3(scale_raw, scale_vec, has_scale_vec)
    call get_num(scale_raw, scale_num, has_scale_num)
    if (has_scale_vec .and. any(scale_vec == 0.0_real64)) then
      call verrn("E301", "scale cannot be 0; the object would " // &
           "disappear", node)
    end if
    if (has_scale_num .and. scale_num == 0.0_real64) then
      call verrn("E301", "scale cannot be 0; the object would " // &
           "disappear", node)
    end if
    if (.not. finite_vec(position) .or. &
        .not. finite_vec(rotation)) then
      call verrn("E301", "object positions and rotations must " // &
           "be plain finite numbers", node)
    end if
    ! tris_est is ONLY for the E820 budget check; never stored.
    tri_props = dyn_copy(props)
    if (has_load) then
      call dyn_dict_set(tri_props, "_load_tris", &
           dyn_int(count_obj_triangles(load_path)))
    end if
    if (has_load) then
      tris_est = estimate_triangles("load", tri_props)
    else
      tris_est = estimate_triangles(prim, tri_props)
    end if
    vs%total_tris = vs%total_tris + tris_est
    raw_tris = dyn_null()
    if (prim == "tris") then
      cand = dyn_dict_get(props, "tris")
      if (.not. py_truthy(cand)) &
           cand = dyn_dict_get(props, "triangles")
      if (.not. py_truthy(cand)) then
        call vfield(node, props, [character(12) :: "triangles", &
                                  "tris"], cand)
      end if
      if (cand%kind == DYN_K_LIST) call dyn_assign(raw_tris, cand)
    end if
    if (has_scale_vec) then
      scale3 = scale_vec
    else if (has_scale_num) then
      scale3 = [scale_num, scale_num, scale_num]
    else
      scale3 = [1.0_real64, 1.0_real64, 1.0_real64]
    end if
    ! capped = bool(props.get("capped", True)) and not props "open"
    capped = py_truthy(dyn_dict_get(props, "capped"))
    if (.not. dyn_dict_has(props, "capped")) capped = .true.
    if (py_truthy(dyn_dict_get(props, "open"))) capped = .false.
    ! IRObject (ir_nodes.py field order).
    ir_obj = dyn_dict()
    call dyn_dict_set(ir_obj, "name", dyn_str(name))
    call dyn_dict_set(ir_obj, "prim", dyn_str(prim))
    if (has_rgb) then
      call dyn_dict_set(ir_obj, "color", rgb_dyn(rgb))
    else
      call dyn_dict_set(ir_obj, "color", dyn_null())
    end if
    call dyn_dict_set(ir_obj, "pos", vec3_dyn(position))
    call dyn_dict_set(ir_obj, "rotate", vec3_dyn(rotation))
    call dyn_dict_set(ir_obj, "scale", vec3_dyn(scale3))
    if (has_size) then
      call dyn_dict_set(ir_obj, "size", dyn_real(size))
    else
      call dyn_dict_set(ir_obj, "size", dyn_null())
    end if
    if (has_size3) then
      call dyn_dict_set(ir_obj, "size3", vec3_dyn(size3))
    else
      call dyn_dict_set(ir_obj, "size3", dyn_null())
    end if
    if (has_radius) then
      call dyn_dict_set(ir_obj, "radius", dyn_real(radius))
    else
      call dyn_dict_set(ir_obj, "radius", dyn_null())
    end if
    if (has_height) then
      call dyn_dict_set(ir_obj, "height", dyn_real(obj_height))
    else
      call dyn_dict_set(ir_obj, "height", dyn_null())
    end if
    if (has_segments) then
      call dyn_dict_set(ir_obj, "segments", dyn_int(segments))
    else
      call dyn_dict_set(ir_obj, "segments", dyn_null())
    end if
    call dyn_dict_set(ir_obj, "detail", dyn_str(detail))
    if (has_shading_emit) &
      call dyn_dict_set(ir_obj, "shading", dyn_str(shading_emit))
    if (has_mirror_emit) &
      call dyn_dict_set(ir_obj, "mirror", dyn_str(mirror_emit))
    call dyn_dict_set(ir_obj, "capped", dyn_bool(capped))
    call dyn_dict_set(ir_obj, "material", dyn_str(material))
    call dyn_dict_set(ir_obj, "triangles", raw_tris)
    if (has_load) then
      call dyn_dict_set(ir_obj, "source_file", dyn_str(load_path))
    else
      call dyn_dict_set(ir_obj, "source_file", dyn_null())
    end if
    exts = dyn_dict()
    if (has_geom_payload) &
      call dyn_dict_set(exts, "geometry", geom_payload)
    call dyn_dict_set(ir_obj, "extensions", exts)
    ! Wave A material/texture extension: only when the object uses
    ! a Wave A feature, so plain v1 objects keep extensions == {}.
    mat_keys = [character(16) :: "metalness", "roughness", &
                "specular", "shininess"]
    if (dyn_dict_has(props, "texture") .or. &
        material == "standard" .or. &
        any([(dyn_dict_has(props, trim(mat_keys(k))), k = 1, 4)]) &
        .or. any([(dyn_dict_has(props, trim(p4_keys(k))), &
                   k = 1, 8)])) then
      ! DISPATCH(ext_materials): apply_to_ir_object attaches
      ! extensions["material"]; validate_material_ext reports
      ! E501 (texture) / E301 messages.
      call dispatch_ext_materials(ir_obj, props, material, node)
    end if
    call dyn_list_push(vs%ir_objects, ir_obj)
    vs%last_obj_name = name
    vs%has_last_obj = .true.
  end subroutine add_object

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


  ! ================================================================
  ! Main (validate.py: validate)
  ! ================================================================

  subroutine validate_program(program, bag, base_dir, scene, ok)
    type(dyn), intent(in) :: program
    type(error_bag_t), intent(inout), target :: bag
    character(*), intent(in) :: base_dir
    type(dyn), intent(out) :: scene
    logical, intent(out) :: ok
    type(dyn) :: prog, node, props, v
    integer :: k
    ! camera
    real(real64) :: cam_pos(3), cam_look(3), cam_up(3)
    real(real64) :: fov, near, far
    type(dyn) :: ir_camera
    ! lights
    type(dyn) :: ir_light, ext_in
    character(:), allocatable :: lkind
    real(real64) :: direction(3), intensity
    integer :: lrgb(3)
    logical :: has_lrgb, is_default_light
    ! loads
    character(:), allocatable :: lpath, full
    ! anims / controls / outputs
    type(dyn) :: ir_anim, ir_output
    character(:), allocatable :: controls_kind

    scene = dyn_null()
    ok = .false.
    ! ---- state init ---------------------------------------------
    last_import_deps = dyn_list()
    vs%bag => bag
    vs%base_dir = base_dir
    vs%light_nodes = dyn_list()
    vs%output_nodes = dyn_list()
    vs%object_nodes = dyn_list()
    vs%anim_nodes = dyn_list()
    vs%load_nodes = dyn_list()
    vs%sprite_nodes = dyn_list()
    vs%text_nodes = dyn_list()
    vs%particles_nodes = dyn_list()
    vs%keys_header_nodes = dyn_list()
    vs%key_nodes = dyn_list()
    vs%filter_nodes = dyn_list()
    vs%instance_nodes = dyn_list()
    vs%shader_nodes = dyn_list()
    vs%morph_nodes = dyn_list()
    vs%bone_nodes = dyn_list()
    vs%skin_nodes = dyn_list()
    vs%has_camera = .false.
    vs%has_controls = .false.
    vs%has_scene = .false.
    vs%camera_node = dyn_null()
    vs%controls_node = dyn_null()
    vs%env_props = dyn_dict()
    vs%scene_name = "untitled"
    vs%scene_shading = ""
    vs%has_scene_shading = .false.
    vs%width = 640_int64
    vs%height = 480_int64
    vs%bg = DEFAULT_BG
    vs%names = dyn_dict()
    vs%ext_stash = dyn_dict()
    vs%total_tris = 0_int64
    vs%ir_lights = dyn_list()
    vs%ir_objects = dyn_list()
    vs%ir_anims = dyn_list()
    vs%ir_outputs = dyn_list()
    vs%last_obj_name = ""
    vs%has_last_obj = .false.

    ! ---- 1. Desugar first (B07) ----------------------------------
    call desugar(program, bag, base_dir, prog)

    ! ---- walk -----------------------------------------------------
    call walk_nodes(statements_of(prog))

    call check_image_dim("scene width", vs%width, .true.)
    call check_image_dim("scene height", vs%height, .true.)

    ! ---- camera (E302) -------------------------------------------
    cam_pos = [3.0_real64, 2.5_real64, 4.0_real64]
    cam_look = [0.0_real64, 0.0_real64, 0.0_real64]
    cam_up = [0.0_real64, 1.0_real64, 0.0_real64]
    fov = 60.0_real64
    near = 0.1_real64
    far = 100.0_real64
    if (vs%has_camera) then
      call dyn_assign(node, vs%camera_node)
      props = props_of(node)
      call vfield(node, props, [character(12) :: "at", "pos", &
                               "position", "eye"], v)
      call vec3_or(v, [3.0_real64, 2.5_real64, 4.0_real64], cam_pos)
      call vfield(node, props, [character(12) :: "look", "target", &
                               "look_at"], v)
      call vec3_or(v, [0.0_real64, 0.0_real64, 0.0_real64], cam_look)
      call vfield(node, props, [character(12) :: "up"], v)
      call vec3_or(v, [0.0_real64, 1.0_real64, 0.0_real64], cam_up)
      call vfield(node, props, [character(12) :: "fov"], v)
      block
        real(real64) :: x
        logical :: has
        call get_num(v, x, has)
        if (has) fov = x
        call vfield(node, props, [character(12) :: "near"], v)
        call get_num(v, x, has)
        if (has) near = x
        call vfield(node, props, [character(12) :: "far"], v)
        call get_num(v, x, has)
        if (has) far = x
      end block
      if (.not. finite_vec(cam_pos) .or. &
          .not. finite_vec(cam_look)) then
        call verrn("E302", "camera positions must be plain " // &
             "finite numbers", node)
      end if
      if (.not. (fov > 0.0_real64 .and. fov < 180.0_real64)) then
        call verrn("E302", "fov is " // rstr(fov) // &
             ", but a camera can only see between 0 and 180 " // &
             "degrees", node)
      end if
      if (.not. (ieee_is_finite(near) .and. near > 0.0_real64)) then
        call verrn("E302", "near is " // rstr(near) // &
             ", but it must be more than 0", node)
      end if
      if (.not. (ieee_is_finite(far) .and. far > near)) then
        call verrn("E302", "'far' (" // rstr(far) // &
             ") must be bigger than 'near' (" // rstr(near) // &
             ")", node)
      end if
      if (all(cam_pos == cam_look)) then
        call verrn("E401", "the camera is standing at the place " // &
             "it is looking at, so it cannot see anything", node)
      end if
    end if
    ir_camera = dyn_dict()
    call dyn_dict_set(ir_camera, "pos", vec3_dyn(cam_pos))
    call dyn_dict_set(ir_camera, "target", vec3_dyn(cam_look))
    call dyn_dict_set(ir_camera, "up", vec3_dyn(cam_up))
    call dyn_dict_set(ir_camera, "fov", dyn_real(fov))
    call dyn_dict_set(ir_camera, "near", dyn_real(near))
    call dyn_dict_set(ir_camera, "far", dyn_real(far))

    ! ---- lights (E302 / E205) -------------------------------------
    do k = 0, max(dyn_list_len(vs%light_nodes), 1) - 1
      is_default_light = dyn_list_len(vs%light_nodes) == 0
      if (is_default_light) then
        lkind = "directional"
        direction = [-0.5_real64, -1.0_real64, -0.7_real64]
        intensity = 1.0_real64
        lrgb = [255, 255, 255]
      else
        node = dyn_list_at(vs%light_nodes, k + 1)
        props = props_of(node)
        call vfield(node, props, [character(12) :: "kind", &
             "type", "mode"], v)
        if (v%kind == DYN_K_NULL) then
          lkind = "directional"
        else
          lkind = to_lower(py_str(v))
        end if
        if (.not. in_words(lkind, LIGHT_KINDS_V1)) then
          call verrn("E205", "light " // repr_str(lkind) // &
               " is not built yet; lights are: " // &
               join_words(LIGHT_KINDS_V1), node)
          cycle
        end if
        if (lkind == "point" .or. lkind == "spot") then
          ext_in = dyn_dict()
          call vfield(node, props, [character(12) :: "at", &
                                   "position"], v)
          call dyn_dict_set(ext_in, "at", v)
          call vfield(node, props, [character(12) :: "look", &
               "target", "look_at"], v)
          call dyn_dict_set(ext_in, "look", v)
          call vfield(node, props, [character(12) :: "distance"], v)
          call dyn_dict_set(ext_in, "distance", v)
          call vfield(node, props, [character(12) :: "decay"], v)
          call dyn_dict_set(ext_in, "decay", v)
          call vfield(node, props, [character(12) :: "angle"], v)
          call dyn_dict_set(ext_in, "angle", v)
          call vfield(node, props, [character(12) :: "penumbra"], v)
          call dyn_dict_set(ext_in, "penumbra", v)
          ! DISPATCH(ext_lights_env): extract_light_ext builds the
          ! payload; validate_light_ext's messages are E302 here.
          call dispatch_ext_light(lkind, ext_in, node)
        end if
        call vfield(node, props, [character(12) :: "dir", &
             "direction", "from", "position"], v)
        call vec3_or(v, [-0.5_real64, -1.0_real64, -0.7_real64], &
             direction)
        call vfield(node, props, [character(12) :: "intensity", &
                                  "strength"], v)
        block
          logical :: has
          call get_num(v, intensity, has)
          if (.not. has) intensity = 1.0_real64
        end block
        call vfield(node, props, [character(12) :: "color", &
                                  "colour"], v)
        if (v%kind /= DYN_K_NULL) then
          call parse_color_val(v, node, lrgb, has_lrgb)
          if (.not. has_lrgb) lrgb = [255, 255, 255]
        else
          lrgb = [255, 255, 255]
        end if
        if (lkind == "directional" .and. &
            (.not. finite_vec(direction) .or. &
             all(direction == 0.0_real64))) then
          call verrn("E302", "a light direction of 0 0 0 points " // &
               "nowhere", node)
        end if
        if (.not. ieee_is_finite(intensity) .or. &
            intensity < 0.0_real64 .or. &
            intensity > 100.0_real64) then
          call verrn("E302", "light intensity is " // &
               rstr(intensity) // ", but it must be 0 to 100", node)
        end if
      end if
      ir_light = dyn_dict()
      call dyn_dict_set(ir_light, "kind", dyn_str(lkind))
      call dyn_dict_set(ir_light, "direction", vec3_dyn(direction))
      call dyn_dict_set(ir_light, "color", rgb_dyn(lrgb))
      call dyn_dict_set(ir_light, "intensity", dyn_real(intensity))
      if (lkind == "point" .or. lkind == "spot") then
        ! Wave A payload rides on the IR light (ext_in now holds
        ! the extract_light_ext product; see dispatch_ext_light).
        block
          integer :: q
          character(12) :: pkeys(6)
          pkeys = [character(12) :: "position", "target", &
                   "distance", "decay", "angle", "penumbra"]
          do q = 1, 6
            call dyn_dict_set(ir_light, trim(pkeys(q)), &
                 dyn_dict_get(ext_in, trim(pkeys(q))))
          end do
        end block
      end if
      call dyn_list_push(vs%ir_lights, ir_light)
    end do

    ! ---- objects + loads (E201/E204/E205/E301/E501) ---------------
    do k = 1, dyn_list_len(vs%object_nodes)
      call add_object(dyn_list_at(vs%object_nodes, k), "", &
           .false., "", .false.)
    end do
    do k = 1, dyn_list_len(vs%load_nodes)
      node = dyn_list_at(vs%load_nodes, k)
      props = props_of(node)
      call vfield(node, props, [character(12) :: "path", "file", &
           "source", "filename"], v)
      if (v%kind /= DYN_K_STR .or. len(v%s) == 0) then
        call verrn("E501", "load needs the path of an .obj file", &
             node)
        cycle
      end if
      lpath = v%s
      if (path_ext_lower(lpath) == ".gltf" .or. &
          path_ext_lower(lpath) == ".glb") then
        ! Wave B (row 19): ext_gltf converts at compile time.
        if (lpath(1:1) == "/") then
          full = lpath
        else
          full = join_path(vs%base_dir, lpath)
        end if
        if (.not. path_is_file(full)) then
          call verrn("E501", "I can't find the file " // &
               repr_str(lpath) // " (looked for " // full // ")", &
               node)
          cycle
        end if
        ! DISPATCH(ext_gltf): load_gltf(full) -> tris IR object.
        call dispatch_ext_gltf(node, lpath, full)
        cycle
      end if
      if (path_ext_lower(lpath) /= ".obj") then
        call verrn("E205", "only .obj files can be loaded in v1; " &
             // repr_str(lpath) // " is not built yet", node)
        cycle
      end if
      if (lpath(1:1) == "/") then
        full = lpath
      else
        full = join_path(vs%base_dir, lpath)
      end if
      if (.not. path_is_file(full)) then
        call verrn("E501", "I can't find the file " // &
             repr_str(lpath) // " (looked for " // full // ")", node)
        cycle
      end if
      call add_object(node, "load", .true., lpath, .true.)
    end do

    ! ---- structure + limits (E402 / E820) --------------------------
    if (dyn_list_len(vs%ir_objects) == 0 .and. &
        dyn_list_len(vs%sprite_nodes) == 0 .and. &
        dyn_list_len(vs%text_nodes) == 0 .and. &
        dyn_list_len(vs%particles_nodes) == 0) then
      call verr("E402", "this scene has no objects to render; " // &
           "add a line like: cube red")
    end if
    if (int(dyn_list_len(vs%ir_objects), int64) > MAX_OBJECTS) then
      call verr("E820", "this scene has " // &
           istr(int(dyn_list_len(vs%ir_objects), int64)) // &
           " objects, but the limit is " // istr(MAX_OBJECTS))
    end if
    if (vs%total_tris > MAX_TRIANGLES) then
      call verr("E820", "this scene needs about " // &
           istr(vs%total_tris) // " triangles, but the limit is " // &
           istr(MAX_TRIANGLES) // "; lower segments or detail")
    end if

    ! ---- animations (E201 / E303) ----------------------------------
    do k = 1, dyn_list_len(vs%anim_nodes)
      node = dyn_list_at(vs%anim_nodes, k)
      props = props_of(node)
      block
        type(dyn) :: kind_raw, targetv, axisv, easev, loopv
        character(:), allocatable :: akind, target, axis_s, ease_s
        real(real64) :: speed, duration
        logical :: has_speed, has_duration
        integer(int64) :: fps
        logical :: has_fps
        call vfield(node, props, [character(12) :: "kind", &
             "motion", "action", "type"], kind_raw)
        if (kind_raw%kind == DYN_K_NULL) then
          akind = ""
        else
          akind = to_lower(strip_ws(py_str(kind_raw)))
        end if
        if (.not. in_words(akind, ANIM_KINDS)) then
          call verrn("E201", "animation kind " // &
               py_repr(kind_raw) // &
               " is missing or unknown; v1 has: " // &
               join_words(ANIM_KINDS), node)
          cycle
        end if
        call vfield(node, props, [character(12) :: "target", &
             "target_name", "object", "name"], targetv)
        if (targetv%kind == DYN_K_NULL) then
          target = "it"
        else
          target = py_str(targetv)
        end if
        if (target == "it" .or. target == "last") then
          if (.not. vs%has_last_obj) then
            call verrn("E201", repr_str(akind) // &
                 " has nothing to animate; there is no object " // &
                 "before it", node)
            cycle
          end if
          target = vs%last_obj_name
        else if (target /= "all" .and. &
                 .not. dyn_dict_has(vs%names, target)) then
          call verrn("E201", akind // " targets " // &
               repr_str(target) // &
               ", but no object is called that", node)
          cycle
        end if
        call vfield(node, props, [character(12) :: "axis"], axisv)
        if (axisv%kind /= DYN_K_NULL) then
          axis_s = to_lower(py_str(axisv))
          if (axis_s /= "x" .and. axis_s /= "y" .and. &
              axis_s /= "z") then
            call verrn("E303", "axis " // py_repr(axisv) // &
                 " is not one of x, y, z", node)
          end if
        else
          axis_s = "y"
        end if
        call vfield(node, props, [character(12) :: "speed"], v)
        call get_num(v, speed, has_speed)
        if (has_speed .and. (.not. ieee_is_finite(speed) .or. &
            abs(speed) > MAX_SPEED)) then
          call verrn("E303", "speed is " // rstr(speed) // &
               ", but it must be between -" // &
               istr(int(MAX_SPEED, int64)) // " and " // &
               istr(int(MAX_SPEED, int64)), node)
        end if
        call vfield(node, props, [character(12) :: "duration"], v)
        call get_num(v, duration, has_duration)
        if (has_duration .and. (.not. ieee_is_finite(duration) &
            .or. duration <= 0.0_real64 .or. &
            duration > MAX_DURATION)) then
          call verrn("E303", "duration is " // rstr(duration) // &
               ", but it must be more than 0 and at most " // &
               istr(int(MAX_DURATION, int64)) // " seconds", node)
        end if
        call vfield(node, props, [character(12) :: "fps"], v)
        call get_int(v, fps, has_fps)
        if (has_fps .and. (fps < MIN_FPS .or. fps > MAX_FPS)) then
          call verrn("E303", "fps is " // istr(fps) // &
               ", but it must be " // istr(MIN_FPS) // " to " // &
               istr(MAX_FPS), node)
        end if
        call vfield(node, props, [character(12) :: "ease"], easev)
        if (easev%kind /= DYN_K_NULL) then
          ease_s = to_lower(py_str(easev))
          if (.not. in_words(ease_s, EASES)) then
            call verrn("E201", "there is no easing called " // &
                 py_repr(easev), node)
          end if
        else
          ease_s = "linear"
        end if
        call vfield(node, props, [character(12) :: "loop", &
                                  "loop_mode"], loopv)
        ir_anim = dyn_dict()
        call dyn_dict_set(ir_anim, "kind", dyn_str(akind))
        call dyn_dict_set(ir_anim, "target", dyn_str(target))
        call dyn_dict_set(ir_anim, "axis", dyn_str(axis_s))
        if (has_speed) then
          call dyn_dict_set(ir_anim, "speed", dyn_real(speed))
        else
          call dyn_dict_set(ir_anim, "speed", &
               dyn_real(90.0_real64))
        end if
        if (has_duration) then
          call dyn_dict_set(ir_anim, "duration", dyn_real(duration))
        else
          call dyn_dict_set(ir_anim, "duration", &
               dyn_real(5.0_real64))
        end if
        if (has_fps) then
          call dyn_dict_set(ir_anim, "fps", dyn_int(fps))
        else
          call dyn_dict_set(ir_anim, "fps", dyn_int(30_int64))
        end if
        call dyn_dict_set(ir_anim, "ease", dyn_str(ease_s))
        if (loopv%kind /= DYN_K_NULL) then
          call dyn_dict_set(ir_anim, "loop", loopv)
        else
          call dyn_dict_set(ir_anim, "loop", dyn_str("forever"))
        end if
        call dyn_list_push(vs%ir_anims, ir_anim)
      end block
    end do

    ! ---- controls (E201 / E205 / E302) ------------------------------
    controls_kind = ""
    if (vs%has_controls) then
      call dyn_assign(node, vs%controls_node)
      props = props_of(node)
      call vfield(node, props, [character(12) :: "kind", "type", &
                               "mode"], v)
      if (v%kind == DYN_K_NULL) then
        controls_kind = "orbit"
      else
        controls_kind = to_lower(py_str(v))
      end if
      if (.not. in_words(controls_kind, CONTROLS_KINDS)) then
        call verrn("E205", "controls " // repr_str(controls_kind) &
             // " are not built yet; v1 has orbit and none", node)
      end if
      block
        real(real64) :: cmin, cmax
        logical :: has_min, has_max
        call vfield(node, props, [character(12) :: "min"], v)
        call get_num(v, cmin, has_min)
        call vfield(node, props, [character(12) :: "max"], v)
        call get_num(v, cmax, has_max)
        if (has_min .and. has_max .and. cmin >= cmax) then
          call verrn("E302", "controls min (" // rstr(cmin) // &
               ") must be smaller than max (" // rstr(cmax) // &
               ")", node)
        end if
      end block
    end if

    ! ---- outputs (E301) ----------------------------------------------
    do k = 1, dyn_list_len(vs%output_nodes)
      node = dyn_list_at(vs%output_nodes, k)
      props = props_of(node)
      block
        type(dyn) :: fmtv, pathv, sizev
        character(:), allocatable :: fmt, ekind
        integer(int64) :: ow, oh
        logical :: has_ow, has_oh
        call vfield(node, props, [character(12) :: "format", &
             "kind", "type"], fmtv)
        if (fmtv%kind == DYN_K_NULL) then
          fmt = "render"
        else
          fmt = to_lower(py_str(fmtv))
        end if
        call vfield(node, props, [character(12) :: "path", &
             "file", "to", "output", "filename"], pathv)
        call vfield(node, props, [character(12) :: "width", "w"], v)
        call get_int(v, ow, has_ow)
        call vfield(node, props, [character(12) :: "height", &
                                  "h"], v)
        call get_int(v, oh, has_oh)
        call vfield(node, props, [character(12) :: "size"], sizev)
        if (sizev%kind == DYN_K_LIST .and. &
            dyn_list_len(sizev) >= 2) then
          block
            integer(int64) :: sw, sh
            logical :: okw, okh
            call get_int(dyn_list_at(sizev, 1), sw, okw)
            if (okw) then
              ow = sw
              has_ow = .true.
            end if
            call get_int(dyn_list_at(sizev, 2), sh, okh)
            if (okh) then
              oh = sh
              has_oh = .true.
            end if
          end block
        end if
        if (fmt == "export" .or. in_words(fmt, EXPORT_KINDS)) then
          if (in_words(fmt, EXPORT_KINDS)) then
            ekind = fmt
          else
            call vfield(node, props, [character(12) :: &
                         "export_kind"], v)
            if (v%kind == DYN_K_NULL) then
              ekind = "json"
            else
              ekind = to_lower(py_str(v))
            end if
          end if
          ir_output = dyn_dict()
          call dyn_dict_set(ir_output, "kind", dyn_str("export"))
          call dyn_dict_set(ir_output, "path", pathv)
          call dyn_dict_set(ir_output, "format", dyn_str(ekind))
          if (has_ow) then
            call dyn_dict_set(ir_output, "width", dyn_int(ow))
          else
            call dyn_dict_set(ir_output, "width", dyn_null())
          end if
          if (has_oh) then
            call dyn_dict_set(ir_output, "height", dyn_int(oh))
          else
            call dyn_dict_set(ir_output, "height", dyn_null())
          end if
          call dyn_list_push(vs%ir_outputs, ir_output)
          cycle
        end if
        if (pathv%kind /= DYN_K_NULL) then
          if (.not. in_words(path_ext_lower(py_str(pathv)), &
               RENDER_EXTS)) then
            call verrn("E301", "a render can only be written " // &
                 "to .ppm or .png, not " // py_repr(pathv), node)
          end if
        end if
        call check_image_dim("render width", ow, has_ow, node)
        call check_image_dim("render height", oh, has_oh, node)
        block
          integer(int64) :: ofps
          logical :: has_ofps
          real(real64) :: odur
          logical :: has_odur
          call vfield(node, props, [character(12) :: "fps"], v)
          call get_int(v, ofps, has_ofps)
          if (has_ofps .and. (ofps < MIN_FPS .or. &
              ofps > MAX_FPS)) then
            call verrn("E303", "fps is " // istr(ofps) // &
                 ", but it must be " // istr(MIN_FPS) // " to " // &
                 istr(MAX_FPS), node)
          end if
          call vfield(node, props, [character(12) :: "duration"], v)
          call get_num(v, odur, has_odur)
          if (has_odur .and. (odur <= 0.0_real64 .or. &
              odur > MAX_DURATION)) then
            call verrn("E303", "duration is " // rstr(odur) // &
                 ", but it must be more than 0 and at most " // &
                 istr(int(MAX_DURATION, int64)) // " seconds", node)
          end if
        end block
        ir_output = dyn_dict()
        call dyn_dict_set(ir_output, "kind", dyn_str("render"))
        if (py_truthy(pathv)) then
          call dyn_dict_set(ir_output, "path", pathv)
        else
          call dyn_dict_set(ir_output, "path", &
               dyn_str(DEFAULT_OUTPUT))
        end if
        call dyn_dict_set(ir_output, "format", dyn_str("render"))
        if (has_ow .and. ow /= 0_int64) then
          call dyn_dict_set(ir_output, "width", dyn_int(ow))
        else
          call dyn_dict_set(ir_output, "width", &
               dyn_int(vs%width))
        end if
        if (has_oh .and. oh /= 0_int64) then
          call dyn_dict_set(ir_output, "height", dyn_int(oh))
        else
          call dyn_dict_set(ir_output, "height", &
               dyn_int(vs%height))
        end if
        call dyn_list_push(vs%ir_outputs, ir_output)
      end block
    end do
    if (dyn_list_len(vs%ir_outputs) == 0) then
      ir_output = dyn_dict()
      call dyn_dict_set(ir_output, "kind", dyn_str("render"))
      call dyn_dict_set(ir_output, "path", dyn_str(DEFAULT_OUTPUT))
      call dyn_dict_set(ir_output, "format", dyn_str("render"))
      call dyn_dict_set(ir_output, "width", dyn_int(vs%width))
      call dyn_dict_set(ir_output, "height", dyn_int(vs%height))
      call dyn_list_push(vs%ir_outputs, ir_output)
    end if


    ! ---- Wave A environment clauses --------------------------------
    if (dyn_dict_len(vs%env_props) > 0) then
      block
        type(dyn) :: stripped, ev
        character(:), allocatable :: key, first, rest
        integer :: sp
        stripped = dyn_dict()
        do k = 1, dyn_dict_len(vs%env_props)
          key = dyn_dict_key_at(vs%env_props, k)
          ev = dyn_dict_value_at(vs%env_props, k)
          if (ev%kind == DYN_K_STR) then
            ! value.split(None, 1): first word + remainder.
            block
              character(:), allocatable :: t
              t = strip_ws(ev%s)
              sp = 0
              do sp = 1, len(t)
                if (is_ws(t(sp:sp))) exit
              end do
              if (sp > len(t)) then
                first = t
                rest = ""
              else
                first = t(1:sp - 1)
                rest = strip_ws(t(sp:))
              end if
              if (in_words(to_lower(first), [character(12) :: &
                   "fog", "tonemap", "tone", "shadow", &
                   "antialias"])) then
                ev = dyn_str(rest)
              end if
            end block
          end if
          call dyn_dict_set(stripped, key, ev)
        end do
        ! DISPATCH(ext_lights_env): extract_env + validate_env
        ! (E302 messages, span-less in Python).
        call dispatch_ext_env(stripped)
      end block
    end if

    ! ---- Wave B entities (rows 17/23/24/29/32) ----------------------
    block
      type(dyn) :: waveb, wb_list, seen, ext_in, headers, raw_keys, &
           ext_out, tracks
      type(dyn) :: snode, sprops
      character(:), allocatable :: sname
      integer :: j
      waveb = dyn_dict()
      seen = dyn_dict()
      ! Sprites.
      wb_list = dyn_list()
      do k = 1, dyn_list_len(vs%sprite_nodes)
        snode = dyn_list_at(vs%sprite_nodes, k)
        sprops = props_of(snode)
        call vfield(snode, sprops, [character(12) :: "name", &
                                   "id"], v)
        if (v%kind == DYN_K_STR .and. len(v%s) > 0) then
          sname = v%s
        else
          sname = "sprite" // istr(int(dyn_list_len(wb_list), &
               int64) + 1_int64)
        end if
        if (dyn_dict_has(seen, sname)) then
          call verrn("E201", "there are two sprites/texts/" // &
               "particles called " // repr_str(sname), snode)
          cycle
        end if
        call dyn_dict_set(seen, sname, dyn_bool(.true.))
        ext_in = dyn_dict()
        call vfield(snode, sprops, [character(12) :: "at", "pos", &
                                   "position"], v)
        call dyn_dict_set(ext_in, "at", v)
        call vfield(snode, sprops, [character(12) :: "size"], v)
        call dyn_dict_set(ext_in, "size", v)
        call vfield(snode, sprops, [character(12) :: "color", &
             "colour", "color_raw"], v)
        call dyn_dict_set(ext_in, "color", v)
        ! DISPATCH(ext_sprites_text): extract_sprite +
        ! validate_sprite (E301 messages).
        call dispatch_ext_sprite(ext_in, snode, ext_out)
        call dyn_dict_set(ext_out, "name", dyn_str(sname))
        call dyn_list_push(wb_list, ext_out)
      end do
      if (dyn_list_len(wb_list) > 0) &
        call dyn_dict_set(waveb, "sprites", wb_list)
      ! Texts (share the sprite name set, per validate.py).
      wb_list = dyn_list()
      do k = 1, dyn_list_len(vs%text_nodes)
        snode = dyn_list_at(vs%text_nodes, k)
        sprops = props_of(snode)
        call vfield(snode, sprops, [character(12) :: "name", &
                                   "id"], v)
        if (v%kind == DYN_K_STR .and. len(v%s) > 0) then
          sname = v%s
        else
          sname = "text" // istr(int(dyn_list_len(wb_list), &
               int64) + 1_int64)
        end if
        if (dyn_dict_has(seen, sname)) then
          call verrn("E201", "there are two sprites/texts/" // &
               "particles called " // repr_str(sname), snode)
          cycle
        end if
        call dyn_dict_set(seen, sname, dyn_bool(.true.))
        ext_in = dyn_dict()
        call vfield(snode, sprops, [character(12) :: "content", &
                                   "text"], v)
        call dyn_dict_set(ext_in, "content", v)
        call vfield(snode, sprops, [character(12) :: "at", "pos", &
                                   "position"], v)
        call dyn_dict_set(ext_in, "at", v)
        call vfield(snode, sprops, [character(12) :: "size"], v)
        call dyn_dict_set(ext_in, "size", v)
        call vfield(snode, sprops, [character(12) :: "color", &
             "colour", "color_raw"], v)
        call dyn_dict_set(ext_in, "color", v)
        ! DISPATCH(ext_sprites_text): extract_text +
        ! validate_text (E301 messages).
        call dispatch_ext_text(ext_in, snode, ext_out)
        call dyn_dict_set(ext_out, "name", dyn_str(sname))
        call dyn_list_push(wb_list, ext_out)
      end do
      if (dyn_list_len(wb_list) > 0) &
        call dyn_dict_set(waveb, "texts", wb_list)
      ! Particles (no shared name check in validate.py).
      wb_list = dyn_list()
      do k = 1, dyn_list_len(vs%particles_nodes)
        snode = dyn_list_at(vs%particles_nodes, k)
        sprops = props_of(snode)
        call vfield(snode, sprops, [character(12) :: "name", &
                                   "id"], v)
        if (v%kind == DYN_K_STR .and. len(v%s) > 0) then
          sname = v%s
        else
          sname = "particles" // istr(int(dyn_list_len(wb_list), &
               int64) + 1_int64)
        end if
        ext_in = dyn_dict()
        do j = 1, 8
          block
            character(12) :: pkeys(8)
            pkeys = [character(12) :: "at", "count", "life", &
                     "speed", "size", "spread", "gravity", "seed"]
            call vfield(snode, sprops, [character(12) :: &
                         pkeys(j)], v)
            if (v%kind /= DYN_K_NULL) &
              call dyn_dict_set(ext_in, trim(pkeys(j)), v)
          end block
        end do
        call vfield(snode, sprops, [character(12) :: "color", &
             "colour", "color_raw"], v)
        if (v%kind /= DYN_K_NULL) &
          call dyn_dict_set(ext_in, "color", v)
        ! DISPATCH(ext_particles): extract_particles +
        ! validate_particles (E301 messages).
        call dispatch_ext_particles(ext_in, snode)
        call dyn_dict_set(ext_in, "name", dyn_str(sname))
        call dyn_list_push(wb_list, ext_in)
      end do
      if (dyn_list_len(wb_list) > 0) &
        call dyn_dict_set(waveb, "particles", wb_list)
      ! Keyframe tracks: validate.py's own target checks are core;
      ! build_tracks / validate_tracks are the dispatch.
      if (dyn_list_len(vs%keys_header_nodes) > 0 .or. &
          dyn_list_len(vs%key_nodes) > 0) then
        headers = dyn_dict()
        do k = 1, dyn_list_len(vs%keys_header_nodes)
          snode = dyn_list_at(vs%keys_header_nodes, k)
          sprops = props_of(snode)
          call vfield(snode, sprops, [character(12) :: "target"], v)
          if (v%kind == DYN_K_STR .and. len(v%s) > 0) then
            block
              type(dyn) :: hdr, dv
              real(real64) :: dur
              logical :: has_dur
              hdr = dyn_dict()
              call vfield(snode, sprops, [character(12) :: &
                           "duration"], dv)
              call get_num(dv, dur, has_dur)
              if (has_dur) then
                call dyn_dict_set(hdr, "duration", dyn_real(dur))
              else
                call dyn_dict_set(hdr, "duration", dyn_null())
              end if
              call vfield(snode, sprops, [character(12) :: &
                           "loop"], dv)
              call dyn_dict_set(hdr, "loop", dv)
              call dyn_dict_set(headers, v%s, hdr)
            end block
          end if
        end do
        raw_keys = dyn_list()
        do k = 1, dyn_list_len(vs%key_nodes)
          snode = dyn_list_at(vs%key_nodes, k)
          sprops = props_of(snode)
          call vfield(snode, sprops, [character(12) :: "target"], v)
          if (v%kind /= DYN_K_STR .or. len(v%s) == 0) then
            call verrn("E201", "'key' needs the name of the " // &
                 "object it animates", snode)
            cycle
          end if
          if (.not. dyn_dict_has(vs%names, v%s)) then
            call verrn("E201", "key targets " // repr_str(v%s) // &
                 ", but no object is called that", snode)
            cycle
          end if
          block
            type(dyn) :: entry, kv2
            real(real64) :: tv(3), tnum
            logical :: has3, has_n
            entry = dyn_dict()
            call dyn_dict_set(entry, "target", v)
            call vfield(snode, sprops, [character(12) :: "time"], &
                        kv2)
            call get_num(kv2, tnum, has_n)
            if (has_n) then
              call dyn_dict_set(entry, "time", dyn_real(tnum))
            else
              call dyn_dict_set(entry, "time", &
                   dyn_real(0.0_real64))
            end if
            call vfield(snode, sprops, [character(12) :: "pos", &
                                       "position"], kv2)
            call get_vec3(kv2, tv, has3)
            if (has3) call dyn_dict_set(entry, "pos", vec3_dyn(tv))
            call vfield(snode, sprops, [character(12) :: "rot", &
                                       "rotate"], kv2)
            call get_vec3(kv2, tv, has3)
            if (has3) call dyn_dict_set(entry, "rot", vec3_dyn(tv))
            call vfield(snode, sprops, [character(12) :: &
                         "scale"], kv2)
            call get_num(kv2, tnum, has_n)
            if (has_n) &
              call dyn_dict_set(entry, "scale", dyn_real(tnum))
            call vfield(snode, sprops, [character(12) :: &
                         "ease"], kv2)
            if (kv2%kind /= DYN_K_NULL) &
              call dyn_dict_set(entry, "ease", &
                   dyn_str(to_lower(py_str(kv2))))
            call dyn_list_push(raw_keys, entry)
          end block
        end do
        ! DISPATCH(ext_keys): build_tracks + validate_tracks
        ! (E201 messages, span-less).
        call dispatch_ext_keys(headers, raw_keys, tracks)
        if (dyn_dict_len(tracks) > 0) &
          call dyn_dict_set(waveb, "keys", tracks)
      end if
      call set_scene_extension("waveb", waveb)
    end block

    ! ---- Wave C entities (rows 3/22/26/30) ---------------------------
    block
      type(dyn) :: wavec, insts, entry, snode, sprops, chain
      character(:), allocatable :: iname, source
      real(real64) :: tv(3)
      logical :: has3
      type(dyn) :: kv2
      wavec = dyn_dict()
      chain = dyn_list()
      if (vs%has_camera) then
        call dyn_assign(node, vs%camera_node)
        props = props_of(node)
        call vfield(node, props, [character(12) :: "ortho"], v)
        if (py_truthy(v)) then
          block
            type(dyn) :: ext_in2
            ext_in2 = dyn_dict()
            call dyn_dict_set(ext_in2, "ortho", dyn_bool(.true.))
            call vfield(node, props, [character(12) :: "size"], v)
            call dyn_dict_set(ext_in2, "size", v)
            call vfield(node, props, [character(12) :: "at", &
                 "pos", "position"], v)
            call dyn_dict_set(ext_in2, "at", v)
            call vfield(node, props, [character(12) :: "look", &
                                       "target"], v)
            call dyn_dict_set(ext_in2, "look", v)
            ! DISPATCH(ext_cameras): extract_camera +
            ! validate_camera (E302 messages).
            call dispatch_ext_camera(ext_in2, node, wavec)
          end block
        end if
      end if
      if (dyn_list_len(vs%filter_nodes) > 0) then
        do k = 1, dyn_list_len(vs%filter_nodes)
          snode = dyn_list_at(vs%filter_nodes, k)
          sprops = props_of(snode)
          block
            type(dyn) :: ext_in2
            ext_in2 = dyn_dict()
            call vfield(snode, sprops, [character(12) :: "name"], v)
            call dyn_dict_set(ext_in2, "name", v)
            call vfield(snode, sprops, [character(12) :: &
                         "amount"], v)
            if (v%kind /= DYN_K_NULL) &
              call dyn_dict_set(ext_in2, "amount", v)
            ! DISPATCH(ext_post): extract_post + validate_post
            ! (E301 messages).
            call dispatch_ext_post(ext_in2, snode, chain)
          end block
        end do
      end if
      if (dyn_list_len(chain) > 0) &
        call dyn_dict_set(wavec, "post", chain)
      ! Instances are pure validate.py core (no ext call).
      insts = dyn_list()
      do k = 1, dyn_list_len(vs%instance_nodes)
        snode = dyn_list_at(vs%instance_nodes, k)
        sprops = props_of(snode)
        call vfield(snode, sprops, [character(12) :: "name", &
                                   "id"], v)
        if (v%kind == DYN_K_STR .and. len(v%s) > 0) then
          iname = v%s
        else
          iname = ""
        end if
        call vfield(snode, sprops, [character(12) :: "source", &
             "of", "target"], v)
        if (v%kind == DYN_K_STR .and. len(v%s) > 0) then
          source = v%s
        else
          source = ""
        end if
        if (len(iname) == 0) then
          call verrn("E201", "'instance' needs a name for the " // &
               "new object", snode)
          cycle
        end if
        if (len(source) == 0) then
          call verrn("E201", "'instance " // iname // &
               "' needs 'of <object>'", snode)
          cycle
        end if
        if (.not. dyn_dict_has(vs%names, source)) then
          call verrn("E201", "instance " // repr_str(iname) // &
               " copies " // repr_str(source) // &
               ", but no object is called that", snode)
          cycle
        end if
        if (dyn_dict_has(vs%names, iname)) then
          call verrn("E201", "there is already an object called " &
               // repr_str(iname), snode)
          cycle
        end if
        entry = dyn_dict()
        call dyn_dict_set(entry, "name", dyn_str(iname))
        call dyn_dict_set(entry, "source", dyn_str(source))
        call vfield(snode, sprops, [character(12) :: "at", "pos", &
                                   "position"], kv2)
        call get_vec3(kv2, tv, has3)
        if (has3) call dyn_dict_set(entry, "pos", vec3_dyn(tv))
        call vfield(snode, sprops, [character(12) :: "rotate", &
                                   "rot"], kv2)
        call get_vec3(kv2, tv, has3)
        if (has3) call dyn_dict_set(entry, "rot", vec3_dyn(tv))
        call vfield(snode, sprops, [character(12) :: "scale"], kv2)
        if (kv2%kind /= DYN_K_NULL) &
          call dyn_dict_set(entry, "scale", kv2)
        call dyn_list_push(insts, entry)
        call dyn_dict_set(vs%names, iname, snode)
      end do
      if (dyn_list_len(insts) > 0) &
        call dyn_dict_set(wavec, "instances", insts)
      call set_scene_extension("wavec", wavec)
    end block

    ! ---- Wave E entities (rows C2/C1) --------------------------------
    call validate_wave_e()

    ! ---- result -------------------------------------------------------
    if (error_bag_has_errors(bag)) then
      scene = dyn_null()
      ok = .false.
      return
    end if
    scene = dyn_dict()
    call dyn_dict_set(scene, "name", dyn_str(vs%scene_name))
    call dyn_dict_set(scene, "width", dyn_int(vs%width))
    call dyn_dict_set(scene, "height", dyn_int(vs%height))
    call dyn_dict_set(scene, "bg", rgb_dyn(vs%bg))
    call dyn_dict_set(scene, "camera", ir_camera)
    call dyn_dict_set(scene, "lights", vs%ir_lights)
    call dyn_dict_set(scene, "objects", vs%ir_objects)
    call dyn_dict_set(scene, "animations", vs%ir_anims)
    call dyn_dict_set(scene, "outputs", vs%ir_outputs)
    block
      type(dyn) :: exts
      exts = dyn_dict()
      call dyn_dict_set(scene, "extensions", exts)
    end block
    call dyn_dict_set(scene, "source_map", dyn_null())
    ! Wave extensions were stashed by set_scene_extension.
    block
      type(dyn) :: exts
      exts = dyn_dict_get(scene, "extensions")
      do k = 1, dyn_dict_len(vs%ext_stash)
        call dyn_dict_set(exts, dyn_dict_key_at(vs%ext_stash, k), &
             dyn_dict_value_at(vs%ext_stash, k))
      end do
      call dyn_dict_set(scene, "extensions", exts)
    end block
    call dyn_dict_set(scene, "base_dir", dyn_str(base_dir))
    ! v2.0 P5: record desugar's import list for the preview watcher
    ! in module state (see f3dc_validate_import_deps below).  It is
    ! deliberately NOT stamped onto the scene dyn: the .scene and
    ! _scene.f90 emitters hash the canonical JSON of the whole IR
    ! into their header stamp, so any extra scene key would change
    ! emitted artifacts for import scenes.
    last_import_deps = dyn_list()
    if (dyn_dict_has(prog, "_import_deps")) &
      last_import_deps = dyn_copy(dyn_dict_get(prog, "_import_deps"))
    ok = .true.
  end subroutine validate_program

  !> v2.0 P5 side channel: the "_import_deps" list (canonical
  !! resolved part-file paths) recorded by desugar during the most
  !! recent f3dc_validate call -- an empty list when that call
  !! imported nothing or has not run yet.  Read by the preview
  !! watcher only; never part of the scene dyn, so no emitted
  !! artifact can observe it.
  function f3dc_validate_import_deps() result(out)
    type(dyn) :: out
    if (last_import_deps%kind == DYN_K_LIST) then
       out = dyn_copy(last_import_deps)
    else
       out = dyn_list()
    end if
  end function f3dc_validate_import_deps

  !> Python scene.extensions[key] = payload, only when the payload
  !! dict is non-empty (the env payload itself is a
  !! DISPATCH(ext_lights_env) product, still deferred).
  subroutine set_scene_extension(key, payload)
    character(*), intent(in) :: key
    type(dyn), intent(in) :: payload
    if (dyn_dict_len(payload) == 0) return
    call dyn_dict_set(vs%ext_stash, key, payload)
  end subroutine set_scene_extension

  !> Wave E section of validate() (shaders + bindings + skinning).
  subroutine validate_wave_e()
    type(dyn) :: wavee, shaders, bindings, bones, morphs, skins
    type(dyn) :: node, props, v, entry, ext_in
    type(dyn) :: obj_names, seen_shaders, bone_names
    character(:), allocatable :: sname, target
    logical :: has_target, rpn_ok, shader_no_expr
    integer :: k, m
    type(dyn) :: rpn
    type(char_list) :: msgs
    wavee = dyn_dict()
    obj_names = dyn_dict()
    do k = 1, dyn_list_len(vs%ir_objects)
      v = dyn_dict_get(dyn_list_at(vs%ir_objects, k), "name")
      if (v%kind == DYN_K_STR .and. len(v%s) > 0) &
        call dyn_dict_set(obj_names, v%s, dyn_bool(.true.))
    end do
    ! Shader definitions.
    shaders = dyn_list()
    seen_shaders = dyn_dict()
    do k = 1, dyn_list_len(vs%shader_nodes)
      node = dyn_list_at(vs%shader_nodes, k)
      props = props_of(node)
      call vfield(node, props, [character(12) :: "name", "id"], v)
      if (v%kind == DYN_K_STR .and. len(v%s) > 0) then
        sname = v%s
      else
        sname = ""
      end if
      call vfield(node, props, [character(12) :: "expr", &
                               "expression"], v)
      if (len(sname) == 0) then
        call verrn("E201", "'shader' needs a name", node)
        cycle
      end if
      if (dyn_dict_has(seen_shaders, sname)) then
        call verrn("E201", "there is already a shader called " // &
             repr_str(sname), node)
        cycle
      end if
      shader_no_expr = v%kind /= DYN_K_STR
      if (.not. shader_no_expr) &
        shader_no_expr = len(strip_ws(v%s)) == 0
      if (shader_no_expr) then
        call verrn("E301", "shader " // repr_str(sname) // &
             " needs an expression, like: shader " // sname // &
             " expr ""c * ndl""", node)
        cycle
      end if
      ! DISPATCH(ext_shader): tokenize_expr + to_rpn (ValueError ->
      ! E301 "shader %r: %s") and validate_shader (E301 messages).
      call dispatch_ext_shader_rpn(sname, v%s, node, rpn, msgs, &
                                   rpn_ok)
      if (.not. rpn_ok) then
        call verrn("E301", "shader " // repr_str(sname) // ": " // &
             char_list_at(msgs, 1), node)
        cycle
      end if
      do m = 1, char_list_len(msgs)
        call verrn("E301", "shader " // repr_str(sname) // ": " // &
             char_list_at(msgs, m), node)
      end do
      call dyn_dict_set(seen_shaders, sname, dyn_bool(.true.))
      entry = dyn_dict()
      call dyn_dict_set(entry, "name", dyn_str(sname))
      call dyn_dict_set(entry, "rpn", rpn)
      call dyn_dict_set(entry, "expr", v)
      call dyn_list_push(shaders, entry)
    end do
    if (dyn_list_len(shaders) > 0) &
      call dyn_dict_set(wavee, "shaders", shaders)
    ! Object-line `shader <name>` bindings (core checks).
    bindings = dyn_dict()
    do k = 1, dyn_list_len(vs%object_nodes)
      node = dyn_list_at(vs%object_nodes, k)
      props = props_of(node)
      call vfield(node, props, [character(12) :: "shader"], v)
      if (v%kind == DYN_K_NULL) cycle
      block
        type(dyn) :: nv
        character(:), allocatable :: oname, bound
        bound = py_str(v)
        call vfield(node, props, [character(12) :: "name", &
                                   "id"], nv)
        if (nv%kind == DYN_K_STR .and. len(nv%s) > 0) then
          oname = nv%s
        else
          oname = ""
        end if
        if (len(oname) == 0) then
          call verrn("E201", "an object using 'shader " // &
               bound // "' needs a name, like: cube hero red " // &
               "shader " // bound, node)
          cycle
        end if
        if (.not. dyn_dict_has(seen_shaders, bound)) then
          call verrn("E201", "object " // repr_str(oname) // &
               " uses shader " // repr_str(bound) // &
               ", but no shader is called that", node)
          cycle
        end if
        call dyn_dict_set(bindings, oname, dyn_str(bound))
      end block
    end do
    if (dyn_dict_len(bindings) > 0) &
      call dyn_dict_set(wavee, "bindings", bindings)
    ! Skinning / morph.
    if (dyn_list_len(vs%morph_nodes) > 0 .or. &
        dyn_list_len(vs%bone_nodes) > 0 .or. &
        dyn_list_len(vs%skin_nodes) > 0) then
      bones = dyn_list()
      bone_names = dyn_dict()
      do k = 1, dyn_list_len(vs%bone_nodes)
        node = dyn_list_at(vs%bone_nodes, k)
        props = props_of(node)
        ext_in = dyn_dict()
        call vfield(node, props, [character(12) :: "name", &
                                   "id"], v)
        call dyn_dict_set(ext_in, "name", v)
        call vfield(node, props, [character(12) :: "at", "pos", &
                                   "position"], v)
        call dyn_dict_set(ext_in, "at", v)
        call vfield(node, props, [character(12) :: "rotate", &
                                   "rot"], v)
        call dyn_dict_set(ext_in, "rotate", v)
        call vfield(node, props, [character(12) :: "radius"], v)
        call dyn_dict_set(ext_in, "radius", v)
        ! DISPATCH(ext_skin): extract_bone + validate_bone (E301).
        block
          character(:), allocatable :: bname
          logical :: has_bname
          call dispatch_ext_bone(ext_in, node, bone_names, &
               bname, has_bname)
          if (has_bname) &
            call dyn_dict_set(bone_names, bname, dyn_bool(.true.))
        end block
        call dyn_list_push(bones, ext_in)
      end do
      morphs = dyn_list()
      do k = 1, dyn_list_len(vs%morph_nodes)
        node = dyn_list_at(vs%morph_nodes, k)
        props = props_of(node)
        ext_in = dyn_dict()
        call vfield(node, props, [character(12) :: "target", &
                                   "name"], v)
        call dyn_dict_set(ext_in, "target", v)
        call vfield(node, props, [character(12) :: "kind"], v)
        call dyn_dict_set(ext_in, "kind", v)
        call vfield(node, props, [character(12) :: "factor"], v)
        call dyn_dict_set(ext_in, "factor", v)
        ! DISPATCH(ext_skin): extract_morph + validate_morph
        ! (E301 messages).
        call dispatch_ext_morph(ext_in, node, target, has_target)
        if (has_target .and. &
            .not. dyn_dict_has(obj_names, target)) then
          call verrn("E201", "morph targets " // &
               repr_str(target) // &
               ", but no object is called that", node)
          cycle
        end if
        call dyn_list_push(morphs, ext_in)
      end do
      skins = dyn_list()
      do k = 1, dyn_list_len(vs%skin_nodes)
        node = dyn_list_at(vs%skin_nodes, k)
        props = props_of(node)
        ext_in = dyn_dict()
        call vfield(node, props, [character(12) :: "target", &
                                   "name"], v)
        call dyn_dict_set(ext_in, "target", v)
        call vfield(node, props, [character(12) :: "bone"], v)
        call dyn_dict_set(ext_in, "bone", v)
        ! DISPATCH(ext_skin): extract_skin + validate_skin (E301).
        call dispatch_ext_skin(ext_in, node, bone_names, target, &
             has_target)
        if (has_target .and. &
            .not. dyn_dict_has(obj_names, target)) then
          call verrn("E201", "skin targets " // &
               repr_str(target) // &
               ", but no object is called that", node)
          cycle
        end if
        call dyn_list_push(skins, ext_in)
      end do
      if (dyn_list_len(bones) > 0) &
        call dyn_dict_set(wavee, "bones", bones)
      if (dyn_list_len(morphs) > 0) &
        call dyn_dict_set(wavee, "morphs", morphs)
      if (dyn_list_len(skins) > 0) &
        call dyn_dict_set(wavee, "skins", skins)
    end if
    call set_scene_extension("wavee", wavee)
  end subroutine validate_wave_e

end module f3dc_validate
