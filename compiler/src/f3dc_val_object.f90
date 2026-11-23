! f3dc_val_object walk + section.f90 -- Forge3D validator, object walk + section family
! (split from f3dc_validate.f90, v3.0 Phase 6 C2).  Behaviour
! is frozen: bodies moved verbatim; diagnostics, their order
! and all artifacts are unchanged.
module f3dc_val_object
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
  use f3dc_val_common
  use f3dc_str, only: to_lower, fmt_int, fmt_real, &
       char_list, char_list_len, char_list_at, char_list_clear
  use f3dc_val_geometry
  use f3dc_val_materials, only: dispatch_ext_materials
  use f3dc_val_gltf, only: dispatch_ext_gltf
  implicit none
  private
  public :: walk_nodes
  public :: walk_scene
  public :: add_object
  public :: val_sec_objects

contains

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

  subroutine val_sec_objects()
    type(dyn) :: node, props, v
    character(:), allocatable :: lpath, full
    integer :: k
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
  end subroutine val_sec_objects

end module f3dc_val_object
