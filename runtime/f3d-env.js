// f3d-env -- Forge3D environment runtime: fog + tonemapping.
// Role: environment post-effects (fog factors, NDC view distance,
// fog blending, tonemapping) for the Forge3D browser runtime.
// ES module (Phase 7); the classic bundle is built from the modules
// by tools/build_runtime.mjs. Zero dependencies: this module uses no
// sibling-runtime globals (the core helpers in runtime/f3d.js are not
// needed here), so it imports nothing. A compatibility footer at the
// bottom attaches the exported names onto globalThis.F3D (and keeps
// the legacy globalThis.F3DEnv alias).
// Mirrors src/fog.f90 and src/tonemapping.f90 EXACTLY (frozen formulas):
//   linear fog amount  f = clamp((dist - near) / (far - near), 0, 1)
//   exp2 fog amount    f = 1 - exp(-(density * dist)^2)
//   view distance from NDC z:
//                      d = (2*near*far) / (far + near - z*(far - near))
//   tonemap 'none':    clamp(x, 0, 1)            (exposure ignored)
//   tonemap 'reinhard': y = x * exposure; y / (1 + y)
//   tonemap 'aces' (Narkowicz): y = x * exposure;
//                      clamp((y*(2.51*y + 0.03)) /
//                            (y*(2.43*y + 0.59) + 0.14), 0, 1)
// Pixels are [r, g, b] integer triples in 0..255; tonemapping works on
// the normalised channel x = c / 255 and returns integers again.
  function clamp01(v) { return v < 0 ? 0 : (v > 1 ? 1 : v); }
  function byte(v) {
    var n = Math.round(v);
    return n < 0 ? 0 : (n > 255 ? 255 : n);
  }

  // Fog amount in 0..1 for a true view distance `dist`.
  function fogFactorLinear(dist, near, far) {
    if (far === near) return dist >= far ? 1 : 0;
    return clamp01((dist - near) / (far - near));
  }
  function fogFactorExp2(dist, density) {
    var t = density * dist;
    return 1 - Math.exp(-(t * t));
  }

  // Undo the perspective divide: NDC z (-1..1) -> positive view distance.
  function viewDistanceFromNdc(z, near, far) {
    return (2 * near * far) / (far + near - z * (far - near));
  }

  // Blend one pixel toward the fog colour by fog amount f (0..1).
  function applyFogPixel(rgb, fogRgb, f) {
    var a = clamp01(f);
    return [
      byte(rgb[0] * (1 - a) + fogRgb[0] * a),
      byte(rgb[1] * (1 - a) + fogRgb[1] * a),
      byte(rgb[2] * (1 - a) + fogRgb[2] * a)
    ];
  }

  // Tonemap one normalised scalar channel. `mode` is 'none',
  // 'reinhard' or 'aces'; `exposure` defaults to 1 and is ignored
  // by 'none'. Unknown modes throw, matching a hard engine error
  // rather than silently picking a curve.
  function tonemapScalar(mode, x, exposure) {
    var e = exposure == null ? 1 : exposure;
    var y;
    if (mode === 'none') return clamp01(x);
    if (mode === 'reinhard') {
      y = x * e;
      return y / (1 + y);
    }
    if (mode === 'aces') {
      y = x * e;
      return clamp01((y * (2.51 * y + 0.03)) /
                     (y * (2.43 * y + 0.59) + 0.14));
    }
    throw new Error('F3DEnv: unknown tonemap mode: ' + mode);
  }
  function tonemapPixel(rgb, mode, exposure) {
    return [
      byte(255 * tonemapScalar(mode, rgb[0] / 255, exposure)),
      byte(255 * tonemapScalar(mode, rgb[1] / 255, exposure)),
      byte(255 * tonemapScalar(mode, rgb[2] / 255, exposure))
    ];
  }

  // Fog one pixel in a single call.
  //   rgb:     [r, g, b] ints 0..255.
  //   distOrZ: either a true view distance, or an NDC z value --
  //            which one is decided ONLY by `cam` (see below), never
  //            guessed from the magnitude of the value.
  //   fogSpec: {mode: 'linear'|'exp2'|'none', near, far, density,
  //             color: [r, g, b]}. For 'linear', fogSpec.near/far win;
  //             when omitted they fall back to cam.near/cam.far.
  //             For 'exp2', fogSpec.density is used. 'none' (or a
  //             null fogSpec) returns the pixel unchanged.
  //   cam:     null/omitted, or {near, far, isNdc}:
  //              isNdc === true  -> distOrZ is NDC z; it is first
  //                converted with viewDistanceFromNdc(distOrZ,
  //                cam.near, cam.far).
  //              isNdc falsy (or cam omitted) -> distOrZ already is
  //                a true view distance and is used as-is.
  //            (cam.input === 'ndc' is also accepted for isNdc true.)
  function fogPixel(rgb, distOrZ, fogSpec, cam) {
    if (!fogSpec || fogSpec.mode === 'none') {
      return [byte(rgb[0]), byte(rgb[1]), byte(rgb[2])];
    }
    var dist = distOrZ;
    var isNdc = !!(cam && (cam.isNdc === true || cam.input === 'ndc'));
    if (isNdc) dist = viewDistanceFromNdc(distOrZ, cam.near, cam.far);
    var f;
    if (fogSpec.mode === 'linear') {
      var near = fogSpec.near != null ? fogSpec.near
        : (cam ? cam.near : undefined);
      var far = fogSpec.far != null ? fogSpec.far
        : (cam ? cam.far : undefined);
      f = fogFactorLinear(dist, near, far);
    } else if (fogSpec.mode === 'exp2') {
      f = fogFactorExp2(dist, fogSpec.density || 0);
    } else {
      throw new Error('F3DEnv: unknown fog mode: ' + fogSpec.mode);
    }
    return applyFogPixel(rgb, fogSpec.color, f);
  }

export {
  fogFactorLinear,
  fogFactorExp2,
  viewDistanceFromNdc,
  applyFogPixel,
  tonemapScalar,
  tonemapPixel,
  fogPixel
};

// Compatibility footer: attach the exported names onto
// globalThis.F3D (creating it if absent) for classic-bundle and
// non-module consumers, and keep the legacy F3DEnv alias.
globalThis.F3D = globalThis.F3D || {};
globalThis.F3D.fogFactorLinear = fogFactorLinear;
globalThis.F3D.fogFactorExp2 = fogFactorExp2;
globalThis.F3D.viewDistanceFromNdc = viewDistanceFromNdc;
globalThis.F3D.applyFogPixel = applyFogPixel;
globalThis.F3D.tonemapScalar = tonemapScalar;
globalThis.F3D.tonemapPixel = tonemapPixel;
globalThis.F3D.fogPixel = fogPixel;
globalThis.F3DEnv = {
  fogFactorLinear: fogFactorLinear,
  fogFactorExp2: fogFactorExp2,
  viewDistanceFromNdc: viewDistanceFromNdc,
  applyFogPixel: applyFogPixel,
  tonemapScalar: tonemapScalar,
  tonemapPixel: tonemapPixel,
  fogPixel: fogPixel
};
