/**
 * f3d.d.ts — TypeScript declarations for the Forge3D browser runtime.
 *
 * v3.0.0 (Phase 7 / release prep): the canonical surface is now the
 * ES-module runtime aggregated by runtime/f3d.mjs:
 *
 *   import { F3D } from "forge3d";            // one namespace object
 *   import { create, worldTris } from "forge3d";  // flat core names
 *   import F3D from "forge3d";                // default = the namespace
 *
 * f3d.mjs re-exports every public name of the fifteen runtime
 * modules (core first, then the sidecars) and assembles them into
 * the single `F3D` namespace object: the core's flat names
 * (create / auto / worldTris / version), one sub-namespace per
 * module under its short name (F3D.geo, F3D.webgl2, ...), the same
 * sub-namespaces under their historical global names
 * (F3D.Forge3DGeo, F3D.WebGL2, ... — deprecated, see below), and
 * the geometry `builders` / `triCount` registries surfaced flat.
 *
 * The classic global is unchanged: loading the classic bundle (or
 * importing f3d.mjs, whose compatibility footers run) publishes
 * the same assembled namespace as `window.F3D` / the bare global
 * `F3D`, so the global declarations at the bottom of this file
 * remain accurate and are kept.
 *
 * Types are pragmatic where the JS is untyped: plain number arrays
 * for vectors / matrices, `unknown` for loosely-shaped geometry and
 * platform objects (WebXR sessions, WebGL renderers). Accuracy of
 * NAMES is the contract here; do not rely on deep structural typing
 * of triangle streams.
 *
 * Scene field shapes follow the f3dc IR contract (ir_version 1).
 */

/** A 3-component tuple: `[x, y, z]`, or `[r, g, b]` for colours. */
declare type F3DVec3 = [number, number, number];

/** A colour / vector as a plain number array (length not checked). */
declare type F3DNum3 = number[];

/** A flat 16-element matrix, column-major (the runtime convention). */
declare type F3DMat4 = number[];

/**
 * A triangle stream as produced by the geometry builders and by
 * `worldTris`: an array of loosely-shaped triangle entries (vertex
 * triples plus optional face index / colour / normals entries).
 */
declare type F3DTriangles = unknown[][];

/** A flat vertex stream: `[x, y, z, x, y, z, ...]`. */
declare type F3DFlatVerts = number[];

/** A list of `[x, y, z]` vertices. */
declare type F3DVerts = F3DNum3[];

/* ------------------------------------------------------------------ */
/* Scene contract (f3dc IR, ir_version 1) — unchanged from v2.        */
/* ------------------------------------------------------------------ */

declare interface F3DCamera {
  pos: F3DVec3;
  target: F3DVec3;
  up: F3DVec3;
  fov: number;
  near: number;
  far: number;
}

declare interface F3DLight {
  kind: string;
  direction: F3DVec3;
  color: F3DVec3;
  intensity: number;
}

declare interface F3DObject {
  name: string;
  prim: string;
  color: F3DVec3 | null;
  pos: F3DVec3;
  rotate: F3DVec3;
  scale: F3DVec3;
  size: number | null;
  radius: number | null;
  height: number | null;
  segments: number | null;
  material: string;
}

declare interface F3DAnim {
  kind: string;
  target: string;
  axis: string;
  speed: number;
  duration: number;
  fps: number;
  ease: string;
  loop: string;
}

declare interface F3DScene {
  name: string;
  width: number;
  height: number;
  bg: F3DVec3;
  camera: F3DCamera;
  lights: F3DLight[];
  objects: F3DObject[];
  animations: F3DAnim[];
  outputs: unknown[];
}

declare interface F3DPlayer {
  canvas?: unknown;
  scene?: F3DScene;
  play(): void;
  pause(): void;
  setTime(t: number): void;
  render(t?: number): void;
  destroy(): void;
}

/* ------------------------------------------------------------------ */
/* Per-module surfaces. Each interface mirrors one runtime module's   */
/* named exports exactly (names as exported by the .js source).       */
/* ------------------------------------------------------------------ */

/** runtime/f3d.js — the core: player creation + world triangles. */
declare interface F3DCoreModule {
  create(
    target: HTMLCanvasElement | HTMLElement,
    scene: F3DScene
  ): F3DPlayer;
  auto(scene: F3DScene): F3DPlayer | null;
  /** World-space triangle stream for `scene` at time `t`. */
  worldTris(scene: F3DScene, t?: number): F3DTriangles;
  readonly version: "3.0.0";
}

/** One geometry builder: parameters vary, always returns triangles. */
declare type F3DBuilder = (...args: number[] | unknown[]) => F3DTriangles;

/** The geometry builder registry (runtime/f3d-geo.js `builders`). */
declare interface F3DBuilders {
  circle(radius?: number, seg?: number): F3DTriangles;
  ring(inner?: number, outer?: number, seg?: number): F3DTriangles;
  capsule(radius?: number, height?: number, seg?: number): F3DTriangles;
  tube(radius?: number, seg?: number, pathPts?: F3DVerts): F3DTriangles;
  lathe(seg?: number, profilePts?: number[][]): F3DTriangles;
  extrude(depth?: number, shapePts?: number[][]): F3DTriangles;
  tetrahedron(r?: number): F3DTriangles;
  octahedron(r?: number): F3DTriangles;
  icosahedron(r?: number): F3DTriangles;
  dodecahedron(r?: number): F3DTriangles;
  torusknot(
    radius?: number,
    tube?: number,
    seg?: number,
    tseg?: number
  ): F3DTriangles;
  [name: string]: F3DBuilder;
}

/**
 * The exact-triangle-count registry (runtime/f3d-geo.js `triCount`):
 * same names and signatures as the builders, returning counts.
 */
declare interface F3DTriCount {
  circle(radius?: number, seg?: number): number;
  ring(inner?: number, outer?: number, seg?: number): number;
  capsule(radius?: number, height?: number, seg?: number): number;
  tube(radius?: number, seg?: number, pathPts?: F3DVerts): number;
  lathe(seg?: number, profilePts?: number[][]): number;
  extrude(depth?: number, shapePts?: number[][]): number;
  tetrahedron(r?: number): number;
  octahedron(r?: number): number;
  icosahedron(r?: number): number;
  dodecahedron(r?: number): number;
  torusknot(radius?: number, tube?: number, seg?: number, tseg?: number): number;
  [name: string]: (...args: number[] | unknown[]) => number;
}

/** runtime/f3d-geo.js — extra geometry builders + triCount. */
declare interface F3DGeoModule extends F3DBuilders {
  triCount: F3DTriCount;
  builders: F3DBuilders;
  /** The module's ready-made registry object (`{ builders, triCount }`). */
  Forge3DGeo: { builders: F3DBuilders; triCount: F3DTriCount };
}

/** Fog description accepted by `fogPixel` (runtime/f3d-env.js). */
declare interface F3DFogSpec {
  /** 'linear' | 'exp2' | 'none'. */
  mode?: string;
  near?: number;
  far?: number;
  density?: number;
  color?: F3DNum3;
  [key: string]: unknown;
}

/** Camera hint accepted by `fogPixel`: NDC-z conversion when set. */
declare interface F3DFogCam {
  near?: number;
  far?: number;
  isNdc?: boolean;
  /** Also accepted for the NDC flag: the string 'ndc'. */
  input?: string;
  [key: string]: unknown;
}

/** runtime/f3d-env.js — fog + tonemapping. */
declare interface F3DEnvModule {
  fogFactorLinear(dist: number, near?: number, far?: number): number;
  fogFactorExp2(dist: number, density?: number): number;
  viewDistanceFromNdc(z: number, near?: number, far?: number): number;
  applyFogPixel(rgb: F3DNum3, fogRgb: F3DNum3, f: number): F3DNum3;
  tonemapScalar(mode: string, x: number, exposure?: number): number;
  tonemapPixel(rgb: F3DNum3, mode: string, exposure?: number): F3DNum3;
  fogPixel(
    rgb: F3DNum3,
    distOrZ: number,
    fogSpec: F3DFogSpec | null,
    cam?: F3DFogCam | null
  ): F3DNum3;
}

/** A PBR material (runtime/f3d-pbr.js); extra fields pass through. */
declare interface F3DMaterial {
  metalness: number;
  roughness: number;
  specular: number;
  shininess: number;
  ambient?: number;
  [key: string]: unknown;
}

/** Options bag for `shadePoint` (runtime/f3d-pbr.js). */
declare interface F3DShadePointOptions {
  /** Base colour, `[r, g, b]` in 0..255. */
  base?: F3DNum3;
  normal?: F3DNum3;
  worldPos?: F3DNum3;
  camPos?: F3DNum3;
  lights?: unknown[];
  material?: Partial<F3DMaterial> | null;
  /** Shadow factor 0..1 (or boolean); default 1. */
  shadow?: number | boolean;
  ambient?: number;
  ambientColor?: F3DNum3;
  [key: string]: unknown;
}

/** runtime/f3d-pbr.js — PBR materials + point shading. */
declare interface F3DPbrModule {
  attenuate(dist: number, distance?: number, decay?: number): number;
  spotFactor(cosT: number, angleDeg?: number, penumbra?: number): number;
  fresnelSchlick(
    cosT: number,
    f0: number | F3DNum3,
    metalness?: number
  ): number | F3DNum3;
  ggxD(ndoth: number, roughness?: number): number;
  specularBRDF(
    normal: F3DNum3,
    viewDir: F3DNum3,
    lightDir: F3DNum3,
    mat: Partial<F3DMaterial> | null | undefined,
    baseColor: F3DNum3
  ): F3DNum3;
  /** Shade one point -> `[r, g, b]` ints in 0..255. */
  shadePoint(o: F3DShadePointOptions): F3DNum3;
  readonly DEFAULT_MATERIAL: F3DMaterial;
}

/** One keyframe of a keyframe track (runtime/f3d-keys.js). */
declare interface F3DKey {
  time: number;
  pos?: F3DVec3;
  rot?: F3DVec3;
  /** Euler degrees, storage form read by `evalTrackQ` when no `quat`. */
  rot_deg?: F3DVec3;
  /** Quaternion `[x, y, z, w]`; takes precedence over `rot`/`rot_deg`. */
  quat?: [number, number, number, number];
  scale?: number | F3DVec3;
  /** Per-axis scale read by `evalTrackQ` (overrides `scale`). */
  scale3?: F3DVec3;
  /** Ease named on a key drives the segment ENDING at that key. */
  ease?: string;
}

/** A keyframe track: `{ target, duration, loop, keys }`. */
declare interface F3DKeyTrack {
  target?: string;
  duration?: number;
  /** 'once' | 'forever' | 'pingpong' (unknown modes act as 'once'). */
  loop?: string;
  /** > 0: key times / duration are frame numbers at this rate. */
  fps?: number;
  keys: F3DKey[];
  [key: string]: unknown;
}

/** A pose evaluated from a track: `{ pos, rot, scale }`. */
declare interface F3DPose {
  pos: F3DVec3;
  rot: F3DVec3;
  scale: number;
}

/** A quaternion pose from `evalTrackQ`: `{ pos, quat, scale3 }`. */
declare interface F3DPoseQ {
  pos: F3DVec3;
  quat: [number, number, number, number];
  scale3: F3DVec3;
}

/** runtime/f3d-keys.js — keyframe tracks + easing. */
declare interface F3DKeysModule {
  /**
   * Ease normalised progress `p`: 'linear' | 'smooth' | 'in' |
   * 'out' | 'cubic-in' | 'cubic-out' | 'cubic-in-out' |
   * 'bezier(x1,y1,x2,y2)' | 'hold' (unknown names act as 'linear').
   */
  ease(name: string, p: number): number;
  evalTrack(track: F3DKeyTrack, t: number): F3DPose;
  /** Phase 5 evaluator: quaternion slerp + per-axis scale + fps. */
  evalTrackQ(track: F3DKeyTrack, t: number): F3DPoseQ;
}

/** A Timeline IR object (format "forge3d-timeline"). */
declare interface F3DTimelineIR {
  format?: string;
  ir_version?: number;
  fps?: { num: number; den: number };
  duration_frames?: number;
  characters?: Array<{ [key: string]: unknown }>;
  tracks?: Array<{ [key: string]: unknown }>;
  dialogue?: F3DDialogueCue[];
  [key: string]: unknown;
}

/** One dialogue cue of a Timeline IR object (half-open span). */
declare interface F3DDialogueCue {
  id?: string;
  scene?: string;
  start_frame: number;
  end_frame: number;
  speaker?: string;
  text?: string;
  [key: string]: unknown;
}

/** A channel pose: `{ channel: value }` (degrees / units / name). */
declare interface F3DChannelPose {
  [channel: string]: number | string;
}

/** Stick-figure proportions (runtime/f3d-timeline.js). */
declare interface F3DProportions {
  thigh: number;
  shin: number;
  torso: number;
  upper_arm: number;
  fore_arm: number;
  head_r: number;
  line_r: number;
  shoulder_half: number;
  hip_half: number;
  neck: number;
}

/** runtime/f3d-timeline.js — Timeline IR evaluation + figure FK. */
declare interface F3DTimelineModule {
  ease(name: string, p: number): number;
  evalChannels(
    timeline: F3DTimelineIR,
    characterId: string,
    frame: number,
    restPose?: F3DChannelPose
  ): F3DChannelPose;
  evalPoseKeys(track: { [key: string]: unknown }, frame: number): F3DPoseQ;
  evalCamera(
    track: { [key: string]: unknown },
    frame: number
  ): { pos: F3DVec3; target: F3DVec3; fov: number };
  figureJoints(
    pose: F3DChannelPose,
    proportionsWord?: string,
    height?: number
  ): { [joint: string]: [number, number] };
  activeDialogue(timeline: F3DTimelineIR, frame: number): F3DDialogueCue[];
  proportionsFor(word?: string): F3DProportions;
  readonly CHANNELS: string[];
}

/**
 * An instance set (runtime/f3d-instanced.js): the shared geometry is
 * held BY REFERENCE, plus the per-instance transform matrices.
 */
declare interface F3DInstanceSet {
  geometry: unknown;
  transforms: F3DMat4[];
}

/** A TRS descriptor accepted by `fromTRS` / `add` (degrees for rot). */
declare interface F3DTRS {
  pos?: F3DNum3;
  position?: F3DNum3;
  rot?: F3DNum3;
  rotate?: F3DNum3;
  rotation?: F3DNum3;
  scale?: number | F3DNum3;
  scl?: number | F3DNum3;
  matrix?: F3DMat4;
  t?: F3DMat4;
  [key: string]: unknown;
}

/** runtime/f3d-instanced.js — instanced meshes + 4x4 matrix helpers. */
declare interface F3DInstancedModule {
  create(geometry?: unknown): F3DInstanceSet;
  /** Append one instance; returns the set (chainable). */
  add(
    set: F3DInstanceSet,
    matrixOrTRS?: F3DMat4 | F3DTRS | null
  ): F3DInstanceSet;
  count(set: F3DInstanceSet): number;
  /** Per-instance matrices (fresh copies), in insertion order. */
  matrices(set: F3DInstanceSet): F3DMat4[];
  compose(
    px?: number,
    py?: number,
    pz?: number,
    rx?: number,
    ry?: number,
    rz?: number,
    scale?: number | F3DNum3
  ): F3DMat4;
  /** Alias of `compose`. */
  trs: F3DInstancedModule["compose"];
  fromTRS(trs: F3DTRS): F3DMat4;
  /** Apply a flat column-major matrix to one `[x, y, z]` point. */
  apply(m: F3DMat4, p: F3DNum3): F3DNum3;
  /** Ordered base vertex stream of a geometry. */
  baseVertices(geometry: unknown): F3DVerts;
  /** Baked vertex stream: every base vertex, per instance, in order. */
  expand(set: F3DInstanceSet): F3DVerts;
  /** The same baked stream as `expand`, flattened to numbers. */
  buildPositions(set: F3DInstanceSet): F3DFlatVerts;
  /** The baked stream grouped back into triangles. */
  expandTriangles(set: F3DInstanceSet): F3DTriangles;
}

/** One step of a post-processing chain (runtime/f3d-post.js). */
declare interface F3DPostStep {
  name: string;
  amount?: number;
  [key: string]: unknown;
}

/** runtime/f3d-post.js — post-processing filter chains. */
declare interface F3DPostModule {
  /**
   * Apply `chain` to `pixels` (RGB or RGBA, length 3*w*h or 4*w*h)
   * in place; returns `pixels`. Unknown filter names are ignored.
   */
  apply(
    pixels: number[] | Uint8Array | Float64Array | unknown,
    w: number,
    h: number,
    chain: F3DPostStep[]
  ): unknown;
}

/** runtime/f3d-shader.js — RPN custom-shader expressions. */
declare interface F3DShaderModule {
  /** Validate an RPN token list; returns the normalised tokens. */
  parseRPN(tokens: unknown[]): unknown[];
  evalRPN(rpn: unknown[], env?: Record<string, number>): number;
  /** Evaluate once and map to a 0..255 channel byte. */
  shadeChannel(rpn: unknown[], env?: Record<string, number>): number;
  /** Shade one pixel -> `[r, g, b]` byte ints. */
  shadeRGB(
    rpn: unknown[],
    baseRGB: F3DNum3,
    envBase?: Record<string, number>
  ): F3DNum3;
}

/** runtime/f3d-skin.js — morphs + skinning (flat vertex streams). */
declare interface F3DSkinModule {
  /** `kind`: 'bulge' | 'taper' | 'squash'. Returns a new flat stream. */
  morphApply(verts: F3DFlatVerts, kind: string, factor: number): F3DFlatVerts;
  skinWeight(dist: number, radius: number): number;
  skinApply(
    verts: F3DFlatVerts,
    pivot: F3DNum3,
    rotDeg: F3DNum3,
    radius: number
  ): F3DFlatVerts;
}

/** runtime/f3d-sprites-text.js — billboards + 3D text triangles. */
declare interface F3DSpritesTextModule {
  /** Billboard basis at `center` seen from `camPos`. */
  spriteBasis(
    center: F3DNum3,
    camPos: F3DNum3
  ): { right: F3DNum3; up: F3DNum3 };
  /** The 4 billboard corners of a sprite of the given size. */
  spriteQuad(center: F3DNum3, size: number, camPos: F3DNum3): F3DVerts;
  /** The 7 bitmap rows of one character of the 5x7 font. */
  glyphRows(ch: string): number[];
  textTriangles(text: string, origin: F3DNum3, size: number): F3DTriangles;
  textWidth(text: string, size: number): number;
  readonly CHARSET: string;
  /** The 5x7 glyph table, indexed via CHARSET. */
  readonly GLYPHS: number[][];
}

/** A particle system description (runtime/f3d-particles.js). */
declare interface F3DParticleSystem {
  origin?: F3DNum3;
  count?: number;
  life?: number;
  speed?: number;
  size?: number;
  spread?: number;
  gravity?: number;
  seed?: number;
  color?: F3DNum3;
  [key: string]: unknown;
}

/** The state of one particle at one time: `{ pos, scale }`. */
declare interface F3DParticleState {
  pos: F3DNum3;
  scale: number;
}

/** runtime/f3d-particles.js — deterministic particle systems. */
declare interface F3DParticlesModule {
  hash01(seed: number, i: number, k: number): number;
  state(sys: F3DParticleSystem, i: number, t: number): F3DParticleState;
  positions(sys: F3DParticleSystem, t: number): F3DParticleState[];
  /** The 4 billboard corners of particle `i` at time `t`. */
  quad(sys: F3DParticleSystem, i: number, t: number, camPos: F3DNum3): F3DVerts;
}

/** Options accepted by the WebGL2 renderer (runtime/f3d-webgl2.js). */
declare interface F3DWebGL2Options {
  lightDir?: F3DNum3;
  ambient?: number;
  flat?: boolean;
  mirror?: unknown;
  clear?: F3DNum3 | number[];
  [key: string]: unknown;
}

/** A WebGL2 renderer handle as returned by webgl2 `create`. */
declare interface F3DWebGL2Renderer {
  gl: unknown;
  program: unknown;
  canvas?: unknown;
  [key: string]: unknown;
}

/** runtime/f3d-webgl2.js — WebGL2 renderer + attach/fallback probe. */
declare interface F3DWebGL2Module {
  readonly VERT_SRC: string;
  readonly FRAG_SRC: string;
  isAvailable(canvas: HTMLCanvasElement | unknown): boolean;
  create(canvas: HTMLCanvasElement | unknown): F3DWebGL2Renderer | null;
  /** Render `tris` with column-major `mvp`; returns triangles drawn. */
  renderScene(
    renderer: F3DWebGL2Renderer,
    tris: F3DTriangles,
    mvp: F3DMat4,
    opts?: F3DWebGL2Options
  ): number;
  projectPoint(mvp: F3DMat4, p: F3DNum3): F3DNum3;
  /** 'webgl2' when create + renderScene succeeded, else 'canvas2d'. */
  attach(
    canvas: HTMLCanvasElement | unknown,
    tris: F3DTriangles,
    mvp: F3DMat4,
    opts?: F3DWebGL2Options
  ): "webgl2" | "canvas2d";
}

/** One stereo view (runtime/f3d-xr.js `stereoViews`). */
declare interface F3DStereoView {
  projectionMatrix: Float32Array | number[];
  viewMatrix: Float32Array | number[] | null;
  viewport: unknown;
}

/** runtime/f3d-xr.js — WebXR sessions + stereo views. */
declare interface F3DXrModule {
  isSupported(): Promise<boolean>;
  /** An XRSession (loosely typed: platform object), or null. */
  requestVRSession(options?: unknown): Promise<unknown>;
  /** An XRReferenceSpace (loosely typed), or null. */
  requestReferenceSpace(session: unknown): Promise<unknown>;
  stereoViews(frame: unknown, refSpace: unknown): F3DStereoView[];
  /** The current XRSession, or null. */
  currentSession(): unknown;
  endSession(): Promise<boolean>;
  /** True when no session is active and the caller should fall back. */
  shouldFallback(): boolean;
  /** Invert a flat 16-element matrix; null when singular. */
  invert4(m: F3DMat4): F3DMat4 | null;
  /** The same `invert4`, under the registry object's alias. */
  _invert4?: F3DXrModule["invert4"];
}

/** A ray/triangle hit (runtime/f3d-raycast.js `rayTriangle`). */
declare interface F3DRayHit {
  t: number;
  u: number;
  v: number;
}

/** A nearest-hit result of `cast` / `pick` (runtime/f3d-raycast.js). */
declare interface F3DCastHit {
  t: number;
  /** Triangle index into the flat triangle soup. */
  index: number;
  point: F3DNum3;
  /** Barycentric weights `[w0, w1, w2]` = `[1-u-v, u, v]`. */
  bary: F3DNum3;
}

/** runtime/f3d-raycast.js — ray/triangle casting + picking. */
declare interface F3DRaycastModule {
  rayTriangle(
    o: F3DNum3,
    d: F3DNum3,
    v1: F3DNum3,
    v2: F3DNum3,
    v3: F3DNum3
  ): F3DRayHit | null;
  /** Cast against a flat triangle soup (9 numbers per triangle). */
  cast(o: F3DNum3, d: F3DNum3, triangles: F3DFlatVerts): F3DCastHit | null;
  pick(
    px: number,
    py: number,
    width: number,
    height: number,
    camPos: F3DNum3,
    camTarget: F3DNum3,
    camUp: F3DNum3,
    fovDeg: number,
    triangles: F3DFlatVerts
  ): F3DCastHit | null;
}

/** runtime/f3d-ortho.js — orthographic camera matrices. */
declare interface F3DOrthoModule {
  ortho(
    left: number,
    right: number,
    bottom: number,
    top: number,
    near: number,
    far: number
  ): F3DMat4;
  fromSize(size: number, aspect: number, near: number, far: number): F3DMat4;
  /** Project by matrix `m`; point as (x, y, z) or one `[x, y, z]`. */
  project(m: F3DMat4, x: F3DNum3 | number, y?: number, z?: number): F3DNum3;
}

/* ------------------------------------------------------------------ */
/* The assembled F3D namespace object (runtime/f3d.mjs `F3D`).        */
/* ------------------------------------------------------------------ */

/**
 * The runtime API exposed as the `F3D` namespace object: the ES
 * module export of f3d.mjs, its default export, and — via the
 * compatibility footers — `window.F3D` / the global `F3D`.
 */
declare interface F3DRuntime extends F3DCoreModule {
  /* One sub-namespace per module, by short name (preferred form). */
  core: F3DCoreModule;
  geo: F3DGeoModule;
  env: F3DEnvModule;
  pbr: F3DPbrModule;
  keys: F3DKeysModule;
  timeline: F3DTimelineModule;
  instanced: F3DInstancedModule;
  post: F3DPostModule;
  shader: F3DShaderModule;
  skin: F3DSkinModule;
  spritesText: F3DSpritesTextModule;
  particles: F3DParticlesModule;
  webgl2: F3DWebGL2Module;
  xr: F3DXrModule;
  raycast: F3DRaycastModule;
  ortho: F3DOrthoModule;

  /* Ready-made registries, surfaced flat as the classic runtime did. */
  builders: F3DBuilders;
  triCount: F3DTriCount;

  /*
   * Legacy global aliases — DEPRECATED.
   * The same sub-namespace objects under the historical global
   * names the classic scripts published (window.Forge3DGeo,
   * window.F3DEnv, ...). Kept for compatibility with code written
   * against the classic era; prefer the short names above
   * (F3D.geo, F3D.env, ...) in new code. Do not delete these
   * declarations while the classic bundle still publishes them.
   */
  /** @deprecated Use `F3D.geo` instead. */
  Forge3DGeo: F3DGeoModule;
  /** @deprecated Use `F3D.env` instead. */
  F3DEnv: F3DEnvModule;
  /** @deprecated Use `F3D.pbr` instead. */
  F3DPBR: F3DPbrModule;
  /** @deprecated Use `F3D.keys` instead. */
  F3DKeys: F3DKeysModule;
  /** @deprecated Use `F3D.timeline` instead. */
  F3DTimeline: F3DTimelineModule;
  /** @deprecated Use `F3D.instanced` instead. */
  F3DInstanced: F3DInstancedModule;
  /** @deprecated Use `F3D.post` instead. */
  F3DPost: F3DPostModule;
  /** @deprecated Use `F3D.shader` instead. */
  Forge3DShader: F3DShaderModule;
  /** @deprecated Use `F3D.skin` instead. */
  Forge3DSkin: F3DSkinModule;
  /** @deprecated Use `F3D.spritesText` instead. */
  F3DSpritesText: F3DSpritesTextModule;
  /** @deprecated Use `F3D.particles` instead. */
  F3DParticles: F3DParticlesModule;
  /** @deprecated Use `F3D.webgl2` instead. */
  WebGL2: F3DWebGL2Module;
  /** @deprecated Use `F3D.webgl2` instead. */
  Forge3DWebGL2: F3DWebGL2Module;
  /** @deprecated Use `F3D.xr` instead. */
  Forge3DXR: F3DXrModule;
  /** @deprecated Use `F3D.raycast` instead. */
  F3DRay: F3DRaycastModule;
  /** @deprecated Use `F3D.ortho` instead. */
  F3DOrtho: F3DOrthoModule;
}

/** The `<f3d-view>` custom element. */
declare interface F3DViewElement extends HTMLElement {
  player: F3DPlayer | null;
  scene: F3DScene | null;
}

/* ------------------------------------------------------------------ */
/* Classic global (kept): the assembled namespace as a bare global.   */
/* ------------------------------------------------------------------ */

declare const F3D: F3DRuntime;

interface Window {
  F3D: F3DRuntime;
  /**
   * @deprecated Legacy per-module globals published by the classic
   * scripts (e.g. `window.Forge3DGeo`, `window.F3DEnv`,
   * `window.Forge3DXR`). Still published by the compatibility
   * footers; prefer the `F3D` namespace object in new code.
   */
  Forge3DGeo?: F3DGeoModule;
  /** @deprecated Use `F3D.env` instead. */
  F3DEnv?: F3DEnvModule;
  /** @deprecated Use `F3D.pbr` instead. */
  F3DPBR?: F3DPbrModule;
  /** @deprecated Use `F3D.keys` instead. */
  F3DKeys?: F3DKeysModule;
  /** @deprecated Use `F3D.timeline` instead. */
  F3DTimeline?: F3DTimelineModule;
  /** @deprecated Use `F3D.instanced` instead. */
  F3DInstanced?: F3DInstancedModule;
  /** @deprecated Use `F3D.post` instead. */
  F3DPost?: F3DPostModule;
  /** @deprecated Use `F3D.shader` instead. */
  Forge3DShader?: F3DShaderModule;
  /** @deprecated Use `F3D.skin` instead. */
  Forge3DSkin?: F3DSkinModule;
  /** @deprecated Use `F3D.spritesText` instead. */
  F3DSpritesText?: F3DSpritesTextModule;
  /** @deprecated Use `F3D.particles` instead. */
  F3DParticles?: F3DParticlesModule;
  /** @deprecated Use `F3D.webgl2` instead. */
  Forge3DWebGL2?: F3DWebGL2Module;
  /** @deprecated Use `F3D.xr` instead. */
  Forge3DXR?: F3DXrModule;
  /** @deprecated Use `F3D.raycast` instead. */
  F3DRay?: F3DRaycastModule;
  /** @deprecated Use `F3D.ortho` instead. */
  F3DOrtho?: F3DOrthoModule;
}

interface HTMLElementTagNameMap {
  "f3d-view": F3DViewElement;
}

/* ------------------------------------------------------------------ */
/* The ES module (runtime/f3d.mjs), as the module "forge3d".          */
/*                                                                    */
/* Flat re-exports follow f3d.mjs: every name a single module       */
/* exports is importable flat. Names exported by MORE THAN ONE      */
/* module (`create`: core + instanced + webgl2; `apply`: instanced  */
/* + post) are ambiguous through the flat form at runtime and are   */
/* declared below as overload sets for convenience — prefer the     */
/* per-module namespace objects (`core`, `instanced`, `webgl2`,     */
/* `post`, also exported here) or the `F3D` namespace object for     */
/* those names.                                                       */
/* ------------------------------------------------------------------ */

declare module "forge3d" {
  /* The assembled namespace object, and the default export. */
  export const F3D: F3DRuntime;
  export default F3D;

  /* The per-module namespace objects. */
  export const core: F3DCoreModule;
  export const geo: F3DGeoModule;
  export const env: F3DEnvModule;
  export const pbr: F3DPbrModule;
  export const keys: F3DKeysModule;
  export const timeline: F3DTimelineModule;
  export const instanced: F3DInstancedModule;
  export const post: F3DPostModule;
  export const shader: F3DShaderModule;
  export const skin: F3DSkinModule;
  export const spritesText: F3DSpritesTextModule;
  export const particles: F3DParticlesModule;
  export const webgl2: F3DWebGL2Module;
  export const xr: F3DXrModule;
  export const raycast: F3DRaycastModule;
  export const ortho: F3DOrthoModule;

  /* Core (runtime/f3d.js), flat. */
  export const version: "3.0.0";
  export function auto(scene: F3DScene): F3DPlayer | null;
  export function worldTris(scene: F3DScene, t?: number): F3DTriangles;

  /*
   * `create` is exported by three modules (core, instanced,
   * webgl2), so the flat binding is ambiguous at runtime; these
   * overloads document the three shapes. Prefer `core.create`,
   * `instanced.create` and `webgl2.create`.
   */
  export function create(
    target: HTMLCanvasElement | HTMLElement,
    scene: F3DScene
  ): F3DPlayer;
  export function create(geometry?: unknown): F3DInstanceSet;
  export function create(
    canvas: HTMLCanvasElement | unknown
  ): F3DWebGL2Renderer | null;

  /* Geometry (runtime/f3d-geo.js), flat. */
  export const builders: F3DBuilders;
  export const triCount: F3DTriCount;
  export const Forge3DGeo: { builders: F3DBuilders; triCount: F3DTriCount };
  export function circle(radius?: number, seg?: number): F3DTriangles;
  export function ring(
    inner?: number,
    outer?: number,
    seg?: number
  ): F3DTriangles;
  export function capsule(
    radius?: number,
    height?: number,
    seg?: number
  ): F3DTriangles;
  export function tube(
    radius?: number,
    seg?: number,
    pathPts?: F3DVerts
  ): F3DTriangles;
  export function lathe(
    seg?: number,
    profilePts?: number[][]
  ): F3DTriangles;
  export function extrude(
    depth?: number,
    shapePts?: number[][]
  ): F3DTriangles;
  export function tetrahedron(r?: number): F3DTriangles;
  export function octahedron(r?: number): F3DTriangles;
  export function icosahedron(r?: number): F3DTriangles;
  export function dodecahedron(r?: number): F3DTriangles;
  export function torusknot(
    radius?: number,
    tube?: number,
    seg?: number,
    tseg?: number
  ): F3DTriangles;

  /* Environment (runtime/f3d-env.js), flat. */
  export function fogFactorLinear(
    dist: number,
    near?: number,
    far?: number
  ): number;
  export function fogFactorExp2(dist: number, density?: number): number;
  export function viewDistanceFromNdc(
    z: number,
    near?: number,
    far?: number
  ): number;
  export function applyFogPixel(
    rgb: F3DNum3,
    fogRgb: F3DNum3,
    f: number
  ): F3DNum3;
  export function tonemapScalar(
    mode: string,
    x: number,
    exposure?: number
  ): number;
  export function tonemapPixel(
    rgb: F3DNum3,
    mode: string,
    exposure?: number
  ): F3DNum3;
  export function fogPixel(
    rgb: F3DNum3,
    distOrZ: number,
    fogSpec: F3DFogSpec | null,
    cam?: F3DFogCam | null
  ): F3DNum3;

  /* PBR (runtime/f3d-pbr.js), flat. */
  export const DEFAULT_MATERIAL: F3DMaterial;
  export function attenuate(
    dist: number,
    distance?: number,
    decay?: number
  ): number;
  export function spotFactor(
    cosT: number,
    angleDeg?: number,
    penumbra?: number
  ): number;
  export function fresnelSchlick(
    cosT: number,
    f0: number | F3DNum3,
    metalness?: number
  ): number | F3DNum3;
  export function ggxD(ndoth: number, roughness?: number): number;
  export function specularBRDF(
    normal: F3DNum3,
    viewDir: F3DNum3,
    lightDir: F3DNum3,
    mat: Partial<F3DMaterial> | null | undefined,
    baseColor: F3DNum3
  ): F3DNum3;
  export function shadePoint(o: F3DShadePointOptions): F3DNum3;

  /* Keys (runtime/f3d-keys.js), flat. */
  export function ease(name: string, p: number): number;
  export function evalTrack(track: F3DKeyTrack, t: number): F3DPose;
  export function evalTrackQ(track: F3DKeyTrack, t: number): F3DPoseQ;

  /* Timeline (runtime/f3d-timeline.js), flat. */
  export function evalChannels(
    timeline: F3DTimelineIR,
    characterId: string,
    frame: number,
    restPose?: F3DChannelPose
  ): F3DChannelPose;
  export function evalPoseKeys(
    track: { [key: string]: unknown },
    frame: number
  ): F3DPoseQ;
  export function evalCamera(
    track: { [key: string]: unknown },
    frame: number
  ): { pos: F3DVec3; target: F3DVec3; fov: number };
  export function figureJoints(
    pose: F3DChannelPose,
    proportionsWord?: string,
    height?: number
  ): { [joint: string]: [number, number] };
  export function activeDialogue(
    timeline: F3DTimelineIR,
    frame: number
  ): F3DDialogueCue[];
  export function proportionsFor(word?: string): F3DProportions;
  export const CHANNELS: string[];

  /* Instancing (runtime/f3d-instanced.js), flat. */
  export function add(
    set: F3DInstanceSet,
    matrixOrTRS?: F3DMat4 | F3DTRS | null
  ): F3DInstanceSet;
  export function count(set: F3DInstanceSet): number;
  export function matrices(set: F3DInstanceSet): F3DMat4[];
  export function compose(
    px?: number,
    py?: number,
    pz?: number,
    rx?: number,
    ry?: number,
    rz?: number,
    scale?: number | F3DNum3
  ): F3DMat4;
  export const trs: F3DInstancedModule["compose"];
  export function fromTRS(trs: F3DTRS): F3DMat4;
  export function baseVertices(geometry: unknown): F3DVerts;
  export function expand(set: F3DInstanceSet): F3DVerts;
  export function buildPositions(set: F3DInstanceSet): F3DFlatVerts;
  export function expandTriangles(set: F3DInstanceSet): F3DTriangles;

  /*
   * `apply` is exported by two modules (instanced: matrix x point;
   * post: filter chain), so the flat binding is ambiguous at
   * runtime; these overloads document both shapes. Prefer
   * `instanced.apply` and `post.apply`.
   */
  export function apply(m: F3DMat4, p: F3DNum3): F3DNum3;
  export function apply(
    pixels: number[] | Uint8Array | Float64Array | unknown,
    w: number,
    h: number,
    chain: F3DPostStep[]
  ): unknown;

  /* Shader (runtime/f3d-shader.js), flat. */
  export function parseRPN(tokens: unknown[]): unknown[];
  export function evalRPN(rpn: unknown[], env?: Record<string, number>): number;
  export function shadeChannel(
    rpn: unknown[],
    env?: Record<string, number>
  ): number;
  export function shadeRGB(
    rpn: unknown[],
    baseRGB: F3DNum3,
    envBase?: Record<string, number>
  ): F3DNum3;

  /* Skin (runtime/f3d-skin.js), flat. */
  export function morphApply(
    verts: F3DFlatVerts,
    kind: string,
    factor: number
  ): F3DFlatVerts;
  export function skinWeight(dist: number, radius: number): number;
  export function skinApply(
    verts: F3DFlatVerts,
    pivot: F3DNum3,
    rotDeg: F3DNum3,
    radius: number
  ): F3DFlatVerts;

  /* Sprites + text (runtime/f3d-sprites-text.js), flat. */
  export const CHARSET: string;
  export const GLYPHS: number[][];
  export function spriteBasis(
    center: F3DNum3,
    camPos: F3DNum3
  ): { right: F3DNum3; up: F3DNum3 };
  export function spriteQuad(
    center: F3DNum3,
    size: number,
    camPos: F3DNum3
  ): F3DVerts;
  export function glyphRows(ch: string): number[];
  export function textTriangles(
    text: string,
    origin: F3DNum3,
    size: number
  ): F3DTriangles;
  export function textWidth(text: string, size: number): number;

  /* Particles (runtime/f3d-particles.js), flat. */
  export function hash01(seed: number, i: number, k: number): number;
  export function state(
    sys: F3DParticleSystem,
    i: number,
    t: number
  ): F3DParticleState;
  export function positions(
    sys: F3DParticleSystem,
    t: number
  ): F3DParticleState[];
  export function quad(
    sys: F3DParticleSystem,
    i: number,
    t: number,
    camPos: F3DNum3
  ): F3DVerts;

  /* WebGL2 (runtime/f3d-webgl2.js), flat. */
  export const VERT_SRC: string;
  export const FRAG_SRC: string;
  export function isAvailable(canvas: HTMLCanvasElement | unknown): boolean;
  export function renderScene(
    renderer: F3DWebGL2Renderer,
    tris: F3DTriangles,
    mvp: F3DMat4,
    opts?: F3DWebGL2Options
  ): number;
  export function projectPoint(mvp: F3DMat4, p: F3DNum3): F3DNum3;
  export function attach(
    canvas: HTMLCanvasElement | unknown,
    tris: F3DTriangles,
    mvp: F3DMat4,
    opts?: F3DWebGL2Options
  ): "webgl2" | "canvas2d";

  /* XR (runtime/f3d-xr.js), flat. */
  export function isSupported(): Promise<boolean>;
  export function requestVRSession(options?: unknown): Promise<unknown>;
  export function requestReferenceSpace(session: unknown): Promise<unknown>;
  export function stereoViews(
    frame: unknown,
    refSpace: unknown
  ): F3DStereoView[];
  export function currentSession(): unknown;
  export function endSession(): Promise<boolean>;
  export function shouldFallback(): boolean;
  export function invert4(m: F3DMat4): F3DMat4 | null;

  /* Raycast (runtime/f3d-raycast.js), flat. */
  export function rayTriangle(
    o: F3DNum3,
    d: F3DNum3,
    v1: F3DNum3,
    v2: F3DNum3,
    v3: F3DNum3
  ): F3DRayHit | null;
  export function cast(
    o: F3DNum3,
    d: F3DNum3,
    triangles: F3DFlatVerts
  ): F3DCastHit | null;
  export function pick(
    px: number,
    py: number,
    width: number,
    height: number,
    camPos: F3DNum3,
    camTarget: F3DNum3,
    camUp: F3DNum3,
    fovDeg: number,
    triangles: F3DFlatVerts
  ): F3DCastHit | null;

  /* Ortho (runtime/f3d-ortho.js), flat. */
  export function ortho(
    left: number,
    right: number,
    bottom: number,
    top: number,
    near: number,
    far: number
  ): F3DMat4;
  export function fromSize(
    size: number,
    aspect: number,
    near: number,
    far: number
  ): F3DMat4;
  export function project(
    m: F3DMat4,
    x: F3DNum3 | number,
    y?: number,
    z?: number
  ): F3DNum3;
}
