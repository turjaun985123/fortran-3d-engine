// f3d.mjs -- Forge3D runtime: the ES module entry point (Phase 7).
//
// This is the file module consumers import:
//
//   import { F3D } from "./f3d.mjs";          // one namespace object
//   import { create, worldTris } from "./f3d.mjs";  // flat core names
//   import F3D from "./f3d.mjs";              // default = the namespace
//
// It aggregates the sixteen runtime modules, in dependency order
// (the core first, then every sidecar -- the same order
// tools/build_runtime.mjs concatenates for the classic bundle):
//
//   f3d.js          core: create / auto / worldTris / version.
//                   f3d.js REMAINS the classic core: it is the only
//                   module a minimal page needs, it still works as
//                   the base of the classic bundle, and every other
//                   module is an optional sidecar layered on it.
//   f3d-geo.js      extra geometry builders + triCount.
//   f3d-env.js      fog + tonemapping.
//   f3d-pbr.js      PBR materials + point shading.
//   f3d-keys.js     keyframe tracks + easing.
//   f3d-timeline.js Timeline IR evaluation + figure FK.
//   f3d-instanced.js  instanced meshes + 4x4 matrix helpers.
//   f3d-post.js     post-processing filter chains.
//   f3d-shader.js   RPN custom-shader expressions.
//   f3d-skin.js     morphs + skinning.
//   f3d-sprites-text.js  billboards + 3D text triangles.
//   f3d-particles.js  deterministic particle systems.
//   f3d-webgl2.js   WebGL2 renderer + attach/fallback probe.
//   f3d-xr.js       WebXR sessions + stereo views.
//   f3d-raycast.js  ray/triangle casting + picking.
//   f3d-ortho.js    orthographic camera matrices.
//
// How the re-exports work -- read this before adding a module:
// each module is imported as a namespace (`import * as geo ...`)
// and ALSO star-re-exported (`export * from ...`), so every public
// name a module exports is importable from here directly. One ES
// modules rule matters: a name exported by MORE THAN ONE module
// (today: `create`, exported by the core, f3d-instanced and
// f3d-webgl2) is ambiguous through a star re-export and is
// therefore NOT bound by the flat form -- it is not an error, the
// name is simply only reachable unambiguously. Such names, and in
// fact every name, are always available on the F3D namespace
// object below, both under each module's short name
// (F3D.webgl2.create, F3D.core.create, F3D.instanced.create) and
// under its historical global name (F3D.WebGL2.create,
// F3D.F3DInstanced.create, ...). Prefer the namespace form in new
// code; use flat imports only for names a single module exports.
//
// Classic consumers are unaffected: importing this aggregator runs
// every module's compatibility footer, and the line at the bottom
// publishes the assembled namespace as globalThis.F3D, matching
// what the classic bundle (build/f3d.bundle.js) provides.

import * as core from "./f3d.js";
import * as geo from "./f3d-geo.js";
import * as env from "./f3d-env.js";
import * as pbr from "./f3d-pbr.js";
import * as keys from "./f3d-keys.js";
import * as timeline from "./f3d-timeline.js";
import * as instanced from "./f3d-instanced.js";
import * as post from "./f3d-post.js";
import * as shader from "./f3d-shader.js";
import * as skin from "./f3d-skin.js";
import * as spritesText from "./f3d-sprites-text.js";
import * as particles from "./f3d-particles.js";
import * as webgl2 from "./f3d-webgl2.js";
import * as xr from "./f3d-xr.js";
import * as raycast from "./f3d-raycast.js";
import * as ortho from "./f3d-ortho.js";

// Flat re-exports: every name each module exports (subject to the
// ambiguity rule in the header -- multiply-exported names such as
// `create` resolve through the F3D namespace object instead).
export * from "./f3d.js";
export * from "./f3d-geo.js";
export * from "./f3d-env.js";
export * from "./f3d-pbr.js";
export * from "./f3d-keys.js";
export * from "./f3d-timeline.js";
export * from "./f3d-instanced.js";
export * from "./f3d-post.js";
export * from "./f3d-shader.js";
export * from "./f3d-skin.js";
export * from "./f3d-sprites-text.js";
export * from "./f3d-particles.js";
export * from "./f3d-webgl2.js";
export * from "./f3d-xr.js";
export * from "./f3d-raycast.js";
export * from "./f3d-ortho.js";

// The per-module namespaces themselves, for unambiguous access to
// multiply-exported names and for consumers that prefer to import
// one sidecar's surface at a time without a separate import path.
export {
  core,
  geo,
  env,
  pbr,
  keys,
  timeline,
  instanced,
  post,
  shader,
  skin,
  spritesText,
  particles,
  webgl2,
  xr,
  raycast,
  ortho,
};

// The single assembled namespace. The core's flat names come first
// (create / auto / worldTris / version -- the surface f3d.d.ts
// describes for the classic global), then one sub-object per
// module under its short name, then the same sub-objects under
// their historical global names (the names the classic scripts
// published as window globals), so code written against either
// era finds the same functions at the same place. Where a module
// exports a ready-made registry object it is surfaced too (today:
// the geometry builders registry, as F3D.builders).
export const F3D = {
  // Core, flat (mirrors the classic globalThis.F3D of f3d.js).
  create: core.create,
  auto: core.auto,
  worldTris: core.worldTris,
  version: core.version,

  // One sub-namespace per module, by short name.
  core: core,
  geo: geo,
  env: env,
  pbr: pbr,
  keys: keys,
  timeline: timeline,
  instanced: instanced,
  post: post,
  shader: shader,
  skin: skin,
  spritesText: spritesText,
  particles: particles,
  webgl2: webgl2,
  xr: xr,
  raycast: raycast,
  ortho: ortho,

  // The same sub-namespaces under their historical global names.
  Forge3DGeo: geo,
  F3DEnv: env,
  F3DPBR: pbr,
  F3DKeys: keys,
  F3DTimeline: timeline,
  F3DInstanced: instanced,
  F3DPost: post,
  Forge3DShader: shader,
  Forge3DSkin: skin,
  F3DSpritesText: spritesText,
  F3DParticles: particles,
  WebGL2: webgl2,
  Forge3DWebGL2: webgl2,
  Forge3DXR: xr,
  F3DRay: raycast,
  F3DOrtho: ortho,

  // Ready-made registries a module exports, surfaced flat where
  // the classic runtime did the same (f3d-geo registers its
  // builders onto the host F3D object).
  ...(geo.builders ? { builders: geo.builders } : {}),
  ...(geo.triCount ? { triCount: geo.triCount } : {}),
};

// Classic compatibility: the assembled namespace is the global,
// replacing the per-module footers' incremental attachments with
// the complete object (same names, plus the sub-namespaces).
globalThis.F3D = F3D;

export default F3D;
