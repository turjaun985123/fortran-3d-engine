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
! ---------------------------------------------------------------------
! v3.0 Phase 6 (C2): this module is now a THIN ORCHESTRATOR.  The
! per-statement validators live in f3dc_val_<family> modules
! behind the section registry in f3dc_val_common (shared state +
! helpers there, exactly once); validate_program keeps the same
! public API and semantics: state init, desugar, walk, registry
! walk in the original section order, result assembly.
! ---------------------------------------------------------------------
  use, intrinsic :: iso_fortran_env, only: int64, real64
  use f3dc_dyn, only: dyn, dyn_null, dyn_bool, dyn_int, &
       dyn_real, dyn_str, dyn_list, dyn_dict, dyn_copy, &
       dyn_assign, dyn_list_push, dyn_list_len, dyn_list_at, &
       dyn_dict_get, dyn_dict_set, dyn_dict_has, dyn_dict_len, &
       dyn_dict_key_at, dyn_dict_value_at, DYN_K_NULL, &
       DYN_K_BOOL, DYN_K_INT, DYN_K_REAL, DYN_K_STR, &
       DYN_K_LIST, DYN_K_DICT
  use f3dc_errors, only: error_bag_t, error_bag_has_errors
  use f3dc_desugar, only: desugar
  use f3dc_val_common
  use f3dc_val_camera, only: val_sec_camera
  use f3dc_val_lightenv, only: val_sec_lights, val_sec_env
  use f3dc_val_object, only: val_sec_objects, walk_nodes
  use f3dc_val_anim, only: val_sec_anims
  use f3dc_val_output, only: val_sec_controls, val_sec_outputs
  use f3dc_val_timeline, only: val_sec_timeline
  use f3dc_val_waveb, only: val_sec_waveb
  use f3dc_val_wavec, only: val_sec_wavec
  use f3dc_val_wavee, only: val_sec_wavee
  implicit none
  private
  public :: validate_program, f3dc_validate_import_deps

  ! v2.0 P5: import record of the most recent validate run
  ! (side channel for the preview watcher; see the accessor below).
  type(dyn) :: last_import_deps

contains

  subroutine validate_program(program, bag, base_dir, scene, ok)
    type(dyn), intent(in) :: program
    type(error_bag_t), intent(inout), target :: bag
    character(*), intent(in) :: base_dir
    type(dyn), intent(out) :: scene
    logical, intent(out) :: ok
    type(dyn) :: prog
    integer :: k
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
    vs%dialogue_nodes = dyn_list()
    vs%has_film = .false.
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

    ! ---- section registry (C2): explicit dispatch table, walked
    ! in registration order == the monolith's section order ==
    ! diagnostic order (camera, lights, objects, anims, controls,
    ! outputs, env, Wave B, Wave C, Wave E).
    call val_reset_registry()
    call val_register("camera", val_sec_camera)
    call val_register("lights", val_sec_lights)
    call val_register("objects", val_sec_objects)
    call val_register("anims", val_sec_anims)
    call val_register("controls", val_sec_controls)
    call val_register("outputs", val_sec_outputs)
    ! ANIM Wave 1 (ANIM-PLAN SS2.3): the timeline section runs
    ! after "outputs" (it needs the render duration/fps only the
    ! outputs section parses) and before "env".
    call val_register("timeline", val_sec_timeline)
    call val_register("env", val_sec_env)
    call val_register("waveb", val_sec_waveb)
    call val_register("wavec", val_sec_wavec)
    call val_register("wavee", val_sec_wavee)
    call val_run_sections()

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
    call dyn_dict_set(scene, "camera", vctx%ir_camera)
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

end module f3dc_validate
