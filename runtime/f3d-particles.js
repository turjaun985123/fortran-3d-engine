// Forge3D Particles sidecar - OPTIONAL module, load AFTER runtime/f3d.js.
// JS mirror of the deterministic particle system in src/particles.f90
// (MASTER-PLAN row 32): a seeded, fixed-formula point-sprite emitter.
// Every particle's state is a pure function of (sys, index, t) -- no
// simulation state, no wall clock, no Math.random -- so a scene renders
// identically in the Fortran engine, here, and on any re-run.
// Plain script, zero deps, no modules.
'use strict';
(function (g) {
var MOD = 2147483648; // 2^31

// Exact (a * b) % 2^31 for a, b < 2^31 using plain numbers. The raw
// product can reach ~2^62, far past the 2^53 exact-double limit, so
// split both factors into 15-bit low / high parts:
//   a*b = aHi*bHi*2^30 + (aHi*bLo + aLo*bHi)*2^15 + aLo*bLo
// Modulo 2^31 only the low bits of each term survive: the 2^30 term
// keeps (aHi*bHi) mod 2, the 2^15 term keeps the middle sum mod 2^16,
// and aLo*bLo < 2^30 stands as-is. Every intermediate stays < 2^53.
function mulMod(a, b) {
  var aHi = Math.floor(a / 32768), aLo = a - aHi * 32768;
  var bHi = Math.floor(b / 32768), bLo = b - bHi * 32768;
  var mid = aHi * bLo + aLo * bHi;
  return ((aHi * bHi % 2) * 1073741824 + (mid % 65536) * 32768
    + aLo * bLo) % MOD;
}

// Deterministic hash -> [0, 1), the frozen contract recipe:
//   x = (seed*1103515245 + i*12345 + k*67890) % 2^31
//   x = (x*1103515245 + 12345) % 2^31
//   u = x / 2^31
// seed is frozen to 0..100000 by validation elsewhere, so the first
// product seed*1103515245 <= ~1.1e14 < 2^53 stays exact; the second
// multiply goes through mulMod for the same reason.
function hash01(seed, i, k) {
  var x = (seed * 1103515245 + i * 12345 + k * 67890) % MOD;
  x = (mulMod(x, 1103515245) + 12345) % MOD;
  return x / MOD;
}

function v3(v, d) { return v == null ? d.slice()
  : [ +v[0] || 0, +v[1] || 0, +v[2] || 0 ]; }
function num(v, d) { return v == null ? d : +v; }

// Normalise a particle-system descriptor, applying the frozen
// defaults (spread 0.5, gravity 0, seed 1; the remaining fields take
// the Fortran ParticleSystem defaults: count 100, life 2, speed 3,
// size 0.2, color [255, 180, 60]).
function normSys(sys) {
  sys = sys || {};
  return {
    origin: v3(sys.origin, [0, 0, 0]),
    count: sys.count == null ? 100 : Math.max(0, Math.floor(sys.count)),
    life: num(sys.life, 2),
    speed: num(sys.speed, 3),
    size: num(sys.size, 0.2),
    spread: num(sys.spread, 0.5),
    gravity: num(sys.gravity, 0),
    seed: num(sys.seed, 1),
    color: v3(sys.color, [255, 180, 60])
  };
}

function dot(a, b) { return a[0]*b[0] + a[1]*b[1] + a[2]*b[2]; }
function cross(a, b) { return [a[1]*b[2] - a[2]*b[1],
  a[2]*b[0] - a[0]*b[2], a[0]*b[1] - a[1]*b[0]]; }
function norm(a) { var l = Math.hypot(a[0], a[1], a[2]);
  return l > 1e-12 ? [a[0]/l, a[1]/l, a[2]/l] : [0, 0, 0]; }

// State of particle i at time t -> {pos: [x,y,z], scale}.
//   age   = ((t + i*(L/N)) % L + L) % L          (L = life > 0)
//   vel   = [(h0-0.5)*2*V*S, S*(0.5+0.5*h1), (h2-0.5)*2*V*S]
//           with h_k = hash01(seed, i, k), V = spread, S = speed
//   pos   = origin + vel*age + [0, -0.5*gravity*age^2, 0]
//   scale = 1 - age/L
function state(sys, i, t) {
  var s = normSys(sys), L = s.life, S = s.speed, V = s.spread;
  var age = 0;
  if (L > 0) {
    var off = s.count > 0 ? i * (L / s.count) : 0;
    age = ((t + off) % L + L) % L;
  }
  var h0 = hash01(s.seed, i, 0), h1 = hash01(s.seed, i, 1),
      h2 = hash01(s.seed, i, 2);
  var vx = (h0 - 0.5) * 2 * V * S, vy = S * (0.5 + 0.5 * h1),
      vz = (h2 - 0.5) * 2 * V * S, a2 = age * age;
  return {
    pos: [s.origin[0] + vx * age,
          s.origin[1] + vy * age - 0.5 * s.gravity * a2,
          s.origin[2] + vz * age],
    scale: L > 0 ? 1 - age / L : 0
  };
}

// States of all count particles at time t (i is 0-based).
function positions(sys, t) {
  var s = normSys(sys), out = [], i;
  for (i = 0; i < s.count; i++) out.push(state(s, i, t));
  return out;
}

// The 4 billboard corners of particle i at time t, seen from camPos,
// in [(-,-), (+,-), (+,+), (-,+)] (right, up) order. Side length is
// size*scale, so each corner sits size*scale*sqrt(2)/2 from the centre.
// Billboard basis (identical to the sprite contract):
//   view_dir = normalize(center - camPos)
//   up_hint  = (0,1,0), or (1,0,0) when |dot(up_hint, view_dir)| > 0.999
//   right    = normalize(cross(up_hint, view_dir))
//   up       = cross(view_dir, right)
function quad(sys, i, t, camPos) {
  var s = normSys(sys), st = state(s, i, t), c = st.pos;
  var view = norm([c[0] - camPos[0], c[1] - camPos[1], c[2] - camPos[2]]);
  if (view[0] === 0 && view[1] === 0 && view[2] === 0) view = [0, 0, 1];
  var hint = Math.abs(dot([0, 1, 0], view)) > 0.999 ? [1, 0, 0] : [0, 1, 0];
  var right = norm(cross(hint, view)), up = cross(view, right);
  var h = s.size * st.scale / 2, out = [], sx, sy, j;
  var signs = [[-1, -1], [1, -1], [1, 1], [-1, 1]];
  for (j = 0; j < 4; j++) { sx = signs[j][0] * h; sy = signs[j][1] * h;
    out.push([c[0] + right[0] * sx + up[0] * sy,
              c[1] + right[1] * sx + up[1] * sy,
              c[2] + right[2] * sx + up[2] * sy]); }
  return out;
}

g.F3DParticles = { hash01: hash01, state: state,
  positions: positions, quad: quad };
if (typeof window !== 'undefined') window.F3DParticles = g.F3DParticles;
})(typeof globalThis !== 'undefined' ? globalThis : this);
