// Forge3D PBR sidecar - OPTIONAL module, load AFTER runtime/f3d.js.
// Mirrors the Fortran modules src/material_pbr.f90 and src/lighting.f90:
// MeshStandard-style Cook-Torrance PBR (GGX D, Smith-Schlick G,
// Fresnel-Schlick), physical point/spot attenuation and spot cone
// falloff, summed as ambient + per-light diffuse*atten*spot*shadow
// (diffuse weighted by 1-ambient, matching the legacy Fortran
// intensity = ambient + (1-ambient)*diffuse for one directional
// light) + specular*255. Plain script, zero deps, no modules.
// The 15,360 B budget of f3d.js does NOT apply to this sidecar.
'use strict';
(function (g) {
var PI = Math.PI, D2R = PI / 180;
function clamp(x, a, b) { return x < a ? a : (x > b ? b : x); }
function dot(a, b) { return a[0]*b[0] + a[1]*b[1] + a[2]*b[2]; }
function sub(a, b) { return [a[0]-b[0], a[1]-b[1], a[2]-b[2]]; }
function norm(a) { var l = Math.hypot(a[0], a[1], a[2]);
  return l > 1e-12 ? [a[0]/l, a[1]/l, a[2]/l] : [0, 0, 0]; }
function v3(v, d) { return v == null ? d.slice()
  : [ +v[0] || 0, +v[1] || 0, +v[2] || 0 ]; }
// Colour input: [r,g,b] in 0..255 (light colour) or 0..1 (base colour).
function c255(c) { return [c[0]/255, c[1]/255, c[2]/255]; }
function cBase(c) { return (c[0] > 1 || c[1] > 1 || c[2] > 1)
  ? c255(c) : [ +c[0] || 0, +c[1] || 0, +c[2] || 0 ]; }

var DEFAULT_MATERIAL = { metalness: 0, roughness: 1, specular: 0.5,
  shininess: 32 };
function material(m) { var o = {}, k;
  for (k in DEFAULT_MATERIAL) o[k] = DEFAULT_MATERIAL[k];
  if (m) for (k in m) o[k] = m[k];
  return o; }

// a = 1/max(dist,1e-4)**decay, capped at 1 (decay 0 -> 1); if
// distance>0, multiply by clamp(1-(dist/distance)**4, 0, 1)**2.
function attenuate(dist, distance, decay) {
  var a = Math.min(1 / Math.pow(Math.max(dist, 1e-4),
    decay == null ? 2 : decay), 1);
  if (distance > 0) { var w = clamp(1 - Math.pow(dist/distance, 4), 0, 1);
    a *= w * w; }
  return a;
}

// Mirrors spot_factor in src/lighting.f90 EXACTLY: the smoothstep
// runs on the ANGLE IN DEGREES (acos of the cos angle), not on cos:
// 1 when ang <= angleDeg*(1-penumbra), 0 when ang >= angleDeg
// (angleDeg default 45, <= 0 -> 0), smoothstep t*t*(3-2t) with
// t = (outer-ang)/(outer-inner) between. penumbra clamped 0..1.
// (Zero spot_dir / zero to-fragment direction -> 0: shadePoint
// checks the vector lengths before calling, as the Fortran does.)
function spotFactor(cosT, angleDeg, penumbra) {
  if (cosT != null && typeof cosT === 'object') {
    penumbra = cosT.penumbra; angleDeg = cosT.angleDeg; cosT = cosT.cos; }
  var outer = Math.max(angleDeg == null ? 45 : angleDeg, 0);
  if (outer <= 0) return 0;
  var inner = outer * (1 - clamp(penumbra || 0, 0, 1));
  var ang = Math.acos(clamp(cosT, -1, 1)) / D2R;
  if (ang <= inner) return 1;
  if (ang >= outer) return 0;
  var t = (outer - ang) / (outer - inner);
  return t * t * (3 - 2 * t);
}

// F = F0 + (1-F0)*(1-cos)**5. F0 is a scalar, an [r,g,b] F0, or (with
// a third argument) a base colour whose F0 = mix(0.04, base, metal).
function fresnelSchlick(cosT, f0, metalness) {
  var m = Math.pow(1 - clamp(cosT, 0, 1), 5), i;
  if (metalness != null) { var b = cBase(f0);
    f0 = [0.04 + (b[0]-0.04)*metalness, 0.04 + (b[1]-0.04)*metalness,
          0.04 + (b[2]-0.04)*metalness]; }
  if (typeof f0 === 'number') return f0 + (1 - f0) * m;
  var F = []; for (i = 0; i < 3; i++) F[i] = f0[i] + (1 - f0[i]) * m;
  return F;
}

// GGX/Trowbridge-Reitz D: alpha = roughness**2 (roughness >= 0.05),
// D = alpha**2 / (pi * (ndoth**2*(alpha**2-1)+1)**2).
function ggxD(ndoth, roughness) {
  var a = Math.pow(clamp(roughness == null ? 1 : roughness, 0.05, 1), 2);
  ndoth = clamp(ndoth, 0, 1);
  var d = ndoth * ndoth * (a * a - 1) + 1;
  return a * a / (PI * d * d);
}
function schlickG(x, k) { return x / (x * (1 - k) + k); }

// Cook-Torrance specular BRDF -> [r,g,b] (unclamped floats):
// D*G*F / (4*ndotv*ndotl), F0 = mix(0.04, baseColor, metalness),
// exactly as pbr_specular's standard branch in material_pbr.f90
// (material.specular/shininess serve its legacy Phong branch).
// Directions: viewDir/lightDir point TOWARD the camera / the light.
function specularBRDF(normal, viewDir, lightDir, mat, baseColor) {
  var m = material(mat), N = norm(normal), V = norm(viewDir),
      L = norm(lightDir), H = norm([V[0]+L[0], V[1]+L[1], V[2]+L[2]]);
  var nv = Math.max(dot(N, V), 0), nl = Math.max(dot(N, L), 0);
  if (nv <= 0 || nl <= 0) return [0, 0, 0];
  var rough = clamp(m.roughness, 0.05, 1), k = Math.pow(rough + 1, 2) / 8;
  var D = ggxD(Math.max(dot(N, H), 0), rough);
  var G = schlickG(nv, k) * schlickG(nl, k);
  var F = fresnelSchlick(Math.max(dot(V, H), 0), cBase(baseColor || [0,0,0]),
    clamp(m.metalness, 0, 1));
  var s = D * G / Math.max(4 * nv * nl, 1e-4);
  return [F[0]*s, F[1]*s, F[2]*s];
}

// Shade one point -> [r,g,b] ints in 0..255.
// o = {base:[r,g,b] 0..255, normal, worldPos, camPos, lights,
//      material, shadow (0..1, default 1), ambient (default 0.25)}.
// Light = {kind:'directional'|'point'|'spot', dir (travel direction,
// directional/spot cone axis is spotDir), pos, color:[255,255,255],
// intensity, distance, decay, angleDeg, penumbra, spotDir}.
function shadePoint(o) {
  var base = v3(o.base, [0, 0, 0]), N = norm(v3(o.normal, [0, 0, 1])),
      wp = v3(o.worldPos, [0, 0, 0]), V = norm(sub(v3(o.camPos, [0,0,0]), wp)),
      m = material(o.material), bn = c255(base),
      amb = o.ambient != null ? o.ambient
        : (m.ambient != null ? m.ambient : 0.25),
      sh = o.shadow == null ? 1 : clamp(o.shadow === true ? 1
        : (o.shadow === false ? 0 : +o.shadow), 0, 1),
      dif = [0, 0, 0], spec = [0, 0, 0], i, j;
  var lights = o.lights || [];
  for (i = 0; i < lights.length; i++) { var li = lights[i],
      inten = li.intensity == null ? 1 : li.intensity,
      lc = li.color ? cBase(li.color) : [1, 1, 1],
      att = 1, spot = 1, L, d;
    if (li.kind === 'point' || li.kind === 'spot') {
      var to = sub(v3(li.pos, [0, 0, 0]), wp);
      d = Math.hypot(to[0], to[1], to[2]); L = norm(to);
      att = attenuate(d, li.distance || 0, li.decay);
      if (li.kind === 'spot') { var sd = v3(li.spotDir || li.dir, [0, 0, -1]),
          tf = sub(wp, v3(li.pos, [0, 0, 0]));
        // Fortran: zero spot_dir (or zero to-fragment) -> factor 0.
        spot = (Math.hypot(sd[0], sd[1], sd[2]) <= 1e-12
          || Math.hypot(tf[0], tf[1], tf[2]) <= 1e-12) ? 0
          : spotFactor(dot(norm(sd), norm(tf)), li.angleDeg, li.penumbra); }
    } else { var dr = v3(li.dir, [0, 0, -1]);
      L = norm([-dr[0], -dr[1], -dr[2]]); }
    var nl = Math.max(dot(N, L), 0); if (nl <= 0) continue;
    var f = nl * att * spot * sh * inten,
        sb = specularBRDF(N, V, L, m, bn);
    for (j = 0; j < 3; j++) { dif[j] += f * lc[j];
      spec[j] += sb[j] * att * spot * sh * inten * lc[j]; }
  }
  var ambC = o.ambientColor ? cBase(o.ambientColor) : [1, 1, 1], out = [];
  for (j = 0; j < 3; j++) // Fortran converts with int(): truncation.
    out[j] = Math.trunc(clamp(base[j] * (amb * ambC[j]
      + (1 - amb) * dif[j]) + spec[j] * 255, 0, 255));
  return out;
}

g.F3DPBR = { attenuate: attenuate, spotFactor: spotFactor,
  fresnelSchlick: fresnelSchlick, ggxD: ggxD,
  specularBRDF: specularBRDF, shadePoint: shadePoint,
  DEFAULT_MATERIAL: DEFAULT_MATERIAL };
if (typeof window !== 'undefined') window.F3DPBR = g.F3DPBR;
})(typeof globalThis !== 'undefined' ? globalThis : this);
