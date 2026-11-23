# Forge3D scene formats — the format contract (ADR-3)

Forge3D has **two** scene formats. Both are emitted by `f3dc build`
for every `.f3d` source, side by side:

| Artifact | Format | Reader | Status |
|---|---|---|---|
| `build/<name>.scene` | v1 text (`forge3d-scene 1` line format) | `scene_3d.scene_load` (`src/scene.f90`) | **Legacy path, frozen** (ADR-1) |
| `build/<name>.json` | Keyed JSON (`"format": "forge3d-scene"`) | `scene_json_3d.scene_load_json` (`src/scene_json.f90`) | **v3 path** (this document) |

Both readers fill the **same** `Scene` type (`scene_3d`), with the
same defaults, so a scene renders the same whichever path loaded it —
wherever the JSON actually carries the data (see *Gaps* below; the
JSON is not yet a superset of the text format).

A third artifact, `build/<name>.legacy.json`, is a legacy sidecar for
the browser runtime. It is **not** an engine scene format and no
engine reader consumes it (the JSON reader happens to accept its
dict-shaped `triangles` entries, see *Objects → triangles*).

## The v1 text format (legacy, frozen)

Line-oriented, positional, unversioned beyond its header line
(`forge3d-scene 1`). Grammar is documented in the header comment of
`src/scene.f90`. It is frozen by ADR-1: the legacy renderer's golden
image (`sha256 28b6a81d…`) must not change, and the v1 reader stays
untouched as the legacy path. New work goes to the JSON path.

**v3.0 Phase 4 additive lines** (the only exception to the freeze:
optional, emitted only when the `.f3d` source uses the new material
features, and ignored by the legacy renderer — every field they set
defaults to its legacy-equivalent value, so the golden cannot
move):

| Line | Meaning |
|---|---|
| `objtex NAME SLOT PATH` | Extra PBR texture slot for a previously defined object; `SLOT` ∈ `normal`, `mr` (metallic-roughness), `emissive`, `occlusion`. The path is resolved like the `objmat` texture path (cwd, then the scene file's directory) and loaded by a post-pass after the read loop: the emissive map loads as sRGB, the other three as linear data, and every loaded slot gets a mip chain (`texture_build_mips`). |
| `objalpha NAME MODE CUTOFF OPACITY` | `MaterialPBR` alpha state: `MODE` integer 0 = opaque, 1 = mask, 2 = blend; `CUTOFF` and `OPACITY` reals (defaults 0.5 / 1). |
| `objemissive NAME R G B` | `MaterialPBR%emissive`: three reals in 0..1, written with the `objmat` line's `%g` float style. |

Unknown slots, unknown object names and short lines follow the
reader's existing unknown-line behaviour (warn + skip, never a
crash).

The `.f3d` DSL surface that produces them (object-line props,
alongside the existing `texture` / `metalness` / … props):
`normalmap "path"`, `mr "path"`, `emissivemap "path"`,
`occlusionmap "path"` (→ `objtex`), `emissive <colour>` (a colour
name, `#rrggbb`, or `rgb r g b`; → `objemissive` as 0..1 floats),
`opacity <number>`, `cutoff <number>` and
`alpha opaque|mask|blend` (→ one combined `objalpha` line when any
of the three is present). Validation: slot paths must name `.ppm`
files (E501, as for `texture`), `opacity`/`cutoff` must be numbers
in 0..1 and `emissive` must resolve to a colour (E301), a bad
`alpha` word is a parse error (E103), and repeating any prop in
one statement is the usual duplicate-prop error (E110).

## The JSON format (v3 path)

- UTF-8 JSON object, pretty-printed by the current emitter.
- `"format": "forge3d-scene"` — required; readers reject any other
  value.
- `"ir_version": 1` — required; see *Versioning*.
- `"version": 2` — the emitter's own schema stamp. It is **not** the
  scene-format version and readers must ignore it; `ir_version` is
  the version that gates compatibility.
- Key order is alphabetical in current output but meaningless;
  readers must not depend on it. Unknown keys at every level are
  ignored without error (forward compatibility within a version).

### Versioning rules

1. `ir_version` is an integer. It bumps on any **breaking** change:
   a key removed, a key's type or meaning changed, a default changed.
2. Adding a new optional key, or a new value to an existing
   enumeration that old readers already skip safely, is **not**
   breaking and does not bump `ir_version`.
3. Readers accept exactly the `ir_version`s they implement (this
   reader: **1**) and reject any other with a clear error naming the
   version found. A missing `ir_version` is an error, not a default.
4. Emitters must always write both `format` and `ir_version`.

### Top-level keys

| Key | Type | Reader behaviour |
|---|---|---|
| `format` | string | Must equal `"forge3d-scene"`, else reject |
| `ir_version` | int | Must be `1`, else reject |
| `version` | int | Ignored (emitter stamp, see above) |
| `name` | string | Ignored (no `Scene` field; the `.scene` header stamp is a comment there too) |
| `width`, `height` | int | `Scene%width/height`; defaults 640×480 |
| `bg` | `[r,g,b]` ints | `Scene%bg`; default `[25,25,35]` |
| `camera` | object | See *Camera* |
| `lights` | array | See *Lights* |
| `objects` | array | See *Objects* |
| `animations` | array | See *Animations* |
| `outputs` | array | First `kind:"render"` entry's `path` → `Scene%output_file` (default `output_render.ppm`); also feeds the still check in the frame-count rule |
| `extensions` | object | `env`, `waveb`, `wavec`, `wavee` sub-objects; see *Extensions*. `dedup_candidates` / `depth_sort` are optimiser hints — ignored |

**Frame count is not stored.** `Scene%frames` is re-derived with the
emitter's own rule (`frame_count` in `f3dc_emit_fortran.f90`): 1 when
there are no animations or any output is a still (`kind`/`format`/
`mode` equal to `"still"`, or `"still": true`); otherwise
`max(1, max over animations of round(duration × fps))`.

### Camera

`camera: {pos, target, up, fov, near, far}` — three `[x,y,z]` arrays
and three numbers. Defaults (missing object or keys) match the v1
reader: pos `(3, 2.5, 4)`, target `(0,0,0)`, up `(0,1,0)`, fov 60,
near 0.1, far 100. Aspect is `width/height`, as in v1. The alias
`position` for `pos` is accepted.

An orthographic camera is **not** expressed here; it lives in
`extensions.wavec.camera` (see *Extensions*).

### Lights

`lights` is an array of `{kind, direction, color, intensity}`:

| `kind` | Mapping |
|---|---|
| `directional` | `direction` → `Scene%light_dir`, `color` → `light_color`, `intensity` → `light_intensity`; sets `has_dir_light`. If several appear, the last wins (v1 behaviour). Becomes `lights%items(1)`. |
| `ambient` | `intensity` → `Scene%ambient` (default 0.25). `color`/`direction` ignored (v1 ambient is a scalar; `lights%ambient_color` stays white). |
| `point` | Extra light, `Light3%kind = 1`. |
| `spot` | Extra light, `Light3%kind = 2`. |
| anything else | Warning printed, entry skipped (never a crash). |

Point/spot field mapping — **read the gap note**:

- **Position**: for point/spot lights the serialiser folds the light
  position into `direction` (there is no `position` key in
  `ir_version 1` output). The reader therefore takes `direction` as
  the position. If a future emitter writes `position` (or `at`), that
  key wins and `direction` is then read as the spot direction.
- Spot direction: from `target`/`look` when present (normalised
  `target − position`); otherwise the default `(0,-1,0)`.
- `distance` (default 0), `decay` (default 2), `angle` (default 45),
  `penumbra` (default 0): read when present; `ir_version 1` output
  does not carry them (see *Gaps*).

Extra lights follow the directional in `Scene%lights%items`, in file
order, and set `has_env`, exactly as the v1 reader assembles them.

### Objects

`objects` is an array; groups and `repeat` blocks are already
expanded by the emitter (group members carry dotted names such as
`duo.hat`; repeats carry suffixed names `ringlet_1..3`), so the
reader sees a flat list, in order.

Per-object keys:

| Key | Mapping |
|---|---|
| `prim` | Primitive name (alias `primitive` accepted); default `cube`. All v1 primitives are supported via the shared `scene_build_object_mesh`: `cube box sphere cylinder cone plane pyramid torus circle ring capsule tube lathe extrude tetrahedron octahedron icosahedron dodecahedron torusknot`, plus `tris` and `load` below. Unknown prims get v1's cube fallback + warning (from the shared builder). |
| `name` | `SceneObject%name`; default `object` |
| `material` | Lower-cased → `mat_name`; default `lambert` |
| `color` | `[r,g,b]` → `color`; absent/null keeps the `[-1,-1,-1]` palette sentinel, as in v1 |
| `pos`, `rotate`, `scale` | `[x,y,z]` → `pos`, `rot_deg`, `scl`; defaults `(0,0,0)`, `(0,0,0)`, `(1,1,1)` |
| `size` | Number → `dim_size`; `null` = missing (the v1 `-1` sentinel). When `size` is null, `size3` is consulted exactly as the emitter's own fallback (scalar, or first element of a list). |
| `radius`, `height` | Number → `dim_radius` / `dim_height`; `null` = missing (`-1`) |
| `segments` | Int → `segments`; `null` = missing (`0`) |
| `shading` | `"smooth"`/`"flat"` → `shading` (only present when authored) |
| `mirror` | `"x"`/`"y"`/`"z"` → `mirror` 1/2/3 (only present when authored) |
| `capped`, `detail` | Ignored — no `Scene` field (builder-internal emitter detail) |
| `source_file` | For `load`/`tris`: see below |
| `triangles` | For `prim:"tris"`: see below; `null` otherwise |
| `extensions` | Per-object sub-object; see below |

Per-primitive defaults after the sentinels (size 2 for cube/box,
radius 1, height 2, segments 16/24/32…, …) are **not** re-implemented
here: both readers call the same `scene_build_object_mesh`, so they
cannot drift.

**`extensions.geometry`** — `{prim, radius, height, size, segments,
inner, outer, path, points, shape, extrude_depth}`. The reader
consumes `path` (tube, `[x,y,z]` points), `points` (lathe, `[x,y]`
points) and `shape` (extrude, `[x,y]` points) into
`SceneObject%pts`; the scalar fields duplicate the top-level
dimension keys and are ignored. As in the v1 fallback, a point list
placed directly at `extensions.path/points/shape` is also honoured.

**`extensions.material`** — `{metalness, roughness, specular,
shininess, texture}`: the JSON home of the v1 `objmat` line. Applied
after the mesh build, with the emitter's own defaults for null
fields (metalness 0, roughness 1, specular 0.5, shininess 32);
`texture` is a PPM path resolved like v1 (cwd, then the scene file's
directory) and loaded with `texture_load_ppm`. Presence of the
sub-object sets `has_env`, as an `objmat` line does. Objects without
it keep the `pbr_from_material` defaults from the shared material
setup.

**v3.0 Phase 4 keys in `extensions.material`** (all optional;
absent keys keep the legacy-equivalent defaults — emissive
`[0,0,0]`, opacity 1, alpha mode 0, cutoff 0.5, no slot textures).
The emitter writes them only when the `.f3d` source uses the new
material keys, so pre-Phase-4 sources produce byte-identical JSON:

| Key | Type | Mapping |
|---|---|---|
| `emissive` | `[r,g,b]` numbers 0..1 | `MaterialPBR%emissive` (the v1 `objemissive` line's data) |
| `opacity` | number | `MaterialPBR%opacity` |
| `alpha` | `"opaque"` / `"mask"` / `"blend"` | `MaterialPBR%alpha_mode` 0 / 1 / 2 |
| `alpha_mode` | int 0/1/2 | `MaterialPBR%alpha_mode` (read when present; the string `alpha` form wins when both appear) |
| `cutoff` (alias `alpha_cutoff`) | number | `MaterialPBR%alpha_cutoff` |
| `normalmap` (alias `normal_texture`) | path string | `SceneObject%normal_path` → `tex_normal`, loaded linear (sRGB off) + mips |
| `mr` (alias `mr_texture`) | path string | `SceneObject%mr_path` → `tex_mr`, loaded linear + mips |
| `emissivemap` (alias `emissive_texture`) | path string | `SceneObject%emissive_map_path` → `tex_emissive`, loaded sRGB + mips |
| `occlusionmap` (alias `occlusion_texture`) | path string | `SceneObject%occl_path` → `tex_occl`, loaded linear + mips |

Slot paths resolve exactly like `texture` (cwd, then the scene
file's directory); a bad file warns and leaves the slot unloaded.

**`extensions.baked_rotation_deg` / `extensions.raw_props`** —
ignored: `baked_rotation_deg` duplicates `rotate`; `raw_props` is the
unresolved `.f3d` property bag kept for tooling.

**`prim: "tris"`** — explicit geometry. `triangles` is an array of
`[ [r,g,b], [[x,y,z],[x,y,z],[x,y,z]] ]` entries (colour first, then
the three vertices). The dict form `{color: [r,g,b], v: [[…],[…],[…]]}`
(`verts`/`vertices`/`points` also accepted for the vertex key), as
carried by the `.legacy.json` sidecar, is accepted too. The object
keeps the palette-sentinel colour `[-1,-1,-1]` and per-triangle
colours, its `pos`/`rotate`/`scale` come from the object fields, and
`source_file` (e.g. the `.gltf` the triangles were loaded from) is
kept in `source_path` for provenance. Triangle normals are recomputed
with `compute_triangle_normal`, as in v1.

**`prim: "load"`** — an imported model. `source_file` (aliases
`path`, `file`; default `model.obj`) is resolved with the v1 rule
(absolute as-is; else cwd if it exists there; else the scene file's
directory) and loaded through the shared builder's `load_obj` path.
See *Gaps* for the resolution caveat.

### Animations

`animations` is an array of `{kind, target, axis, speed, duration,
fps, ease, loop}` → `SceneAnim`, with the emitter defaults the v1
reader mirrors: kind `spin`, target `all`, axis `y`, speed 90,
duration 5, fps 30, ease `linear`, loop `forever`. String fields are
lower-cased for `kind`/`axis`/`ease`/`loop`, as the v1 emitter writes
them lower-case. All v1 animation kinds (`spin`, `bob`, `pulse`, …)
are carried — kinds are data, not reader logic.

### Extensions

**`extensions.env`** — the scene environment, mirroring the v1
`fog`/`tonemap`/`shadow` lines:

- `fog`: `null`, or `{mode: "linear", near, far, color}` /
  `{mode: "exp2", density, color}` / `{mode: "none"}`.
- `tonemap`: `{mode: "none"|"reinhard"|"aces", exposure}`.
- `shadow`: `{mode: "off"|"on"|"soft", size}`.

**`extensions.waveb`** — Wave B entities:

- `sprites`: `[{name, at|pos, size, color}]` → `SceneSprite`.
- `texts`: `[{name, at|pos, size, color, content|text}]` →
  `SceneText`.
- `particles`: `[{name, origin|at|pos, count, life, speed, size,
  color, spread, gravity, seed}]` → `SceneParticles` (defaults from
  `particle_system_init`, as the v1 line's fields are explicit).
- `keys`: an **object keyed by target name**; each value is
  `{duration, loop, keys: [{time, pos, rot, scale, ease}]}` →
  `KeyTrack`/`KeyFrame`. (This is the one place the format uses a
  dictionary as a map; the reader enumerates its members.)

**`extensions.wavec`** — Wave C:

- `camera`: `{type: "ortho", size}` → `Scene%ortho`, `ortho_size`.
- `post`: `[{name, amount}]` → the post chain, in order (cap 16, as
  in v1).
- `instances`: `[{name, source, pos, rot, scale}]` → a copy of the
  named object's built mesh/pose with its own placement, exactly the
  v1 `instance` semantics (scalar scale, or the first element of a
  list scale, applied uniformly).

**`extensions.wavee`** — Wave E:

- `shaders`: `[{name, rpn: [token, …]}]` → shader definitions
  (`shader_parse`); unparseable defs warn and are skipped.
- `bindings`: an object `{object_name: shader_name}` → per-object
  shader binding.
- `bones`: `[{name, at, rotate, radius}]` → scene bones.
- `morphs`: `[{target, kind, factor}]`, `skins`: `[{target, bone}]`
  → applied after all objects exist, with the same unknown-name
  warnings as v1.

## Gaps — what the JSON cannot yet express (stated plainly)

These are format gaps in `ir_version 1` **output**, not reader
shortcuts; the reader already honours the fix keys if a future
emitter writes them (without an `ir_version` bump, per rule 2 above,
since old readers skip them safely).

1. **Point/spot light parameters.** `distance`, `decay`, `angle`,
   `penumbra` and the spot target are dropped by the IR serialiser
   (`ir_to_dict` writes only `kind/direction/color/intensity`).
   The reader substitutes the documented defaults (0 / 2 / 45 / 0,
   spot direction `(0,-1,0)`), so a JSON-loaded lighting scene's
   spot cone and falloff differ from the v1 load of the same scene
   (e.g. `lighting-showcase`: v1 spot angle 40, penumbra 0.5,
   direction ≈ `(0.349,-0.814,-0.465)`). Fix: serialise
   `position`, `target`, `distance`, `decay`, `angle`, `penumbra`
   on light objects.
2. **`load` source resolution.** `source_file` is relative to the
   `.f3d` source (e.g. `"../model.obj"`), and the JSON carries no
   `base_dir` (the `.scene` emitter rewrites the path to an absolute
   one using the IR's `base_dir`). A JSON load can therefore miss a
   model the v1 load finds, leaving that object's mesh empty (with
   the builder's warning). Prim/name/transform are unaffected.
   Fix: serialise `base_dir`, or rewrite `source_file` to an
   absolute path like the text emitter does.
3. **No explicit frame count / scene name field in the `Scene`.**
   Frame count is re-derived (see above) rather than stored; the
   scene `name` has no `Scene` field in either reader. Neither is a
   divergence today — both are listed so a future need is a
   deliberate format change, not a surprise.

Everything else the v1 reader consumes from a compiler-emitted
`.scene` — all primitives and their defaults, materials/PBR/texture,
fog/tonemap/shadow, sprites/texts/particles, keyframe tracks, ortho
camera, post chain, instances, shader defs/bindings, bones,
morphs and skins — has a mapped JSON home above and is covered by
`tests/fortran/test_scene_json.f90`, which loads both artifacts of
eight built examples and asserts structural equality (printing the
gap-1/gap-2 differences rather than asserting them away).
