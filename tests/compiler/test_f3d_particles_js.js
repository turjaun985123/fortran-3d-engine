'use strict';
/* Port of test_f3d_particles_js.py (Forge3D Wave B seat B72) to
 * plain Node.js: tests for the deterministic particle sidecar
 * runtime/f3d-particles.js (MASTER-PLAN row 32), the JS mirror
 * of src/particles.f90.
 *
 * Standalone-runnable:
 *
 *     node tests/compiler/test_f3d_particles_js.js
 *
 * The size/existence checks always run. The numeric checks load
 * the sidecar in-process (the Python original shelled out to
 * `node -e` snippets).
 *
 * The expected hash values are derived in JS directly from the
 * frozen contract recipe (exact integer arithmetic), never
 * copied from the sidecar output, so the two implementations
 * cross-check each other.
 */
const assert = require('assert');
const fs = require('fs');
const path = require('path');

const REPO = path.join(__dirname, '..', '..');
const JS_PATH = path.join(REPO, 'runtime', 'f3d-particles.js');
const MAX_BYTES = 7680;
const MOD = 2147483648;  // 2^31

const tests = [];
function test(name, fn) { tests.push([name, fn]); }

// The Python PREAMBLE: expose `window` and bind the export as `P`,
// plus the near helper.
let P = null;
let loadError = null;
try {
  global.window = globalThis;
  eval(fs.readFileSync(JS_PATH, 'utf8'));
  P = globalThis.F3DParticles;
} catch (e) { loadError = e; }
function needP() {
  if (loadError) throw loadError;
  return P;
}
const near = (a, b, e) => Math.abs(a - b) <= (e || 1e-9);

// One shared system descriptor, used by several tests; the JS
// mirror below computes its states independently. (The Python
// SYS_JS literal is the same object.)
const SYS = {
  origin: [1.0, 2.0, 3.0], count: 10, life: 2.0, speed: 3.0,
  size: 0.5, spread: 0.5, gravity: 4.0, seed: 7,
  color: [255, 128, 0],
};
const SYS_JS = {origin: [1, 2, 3], count: 10, life: 2, speed: 3,
                size: 0.5, spread: 0.5, gravity: 4, seed: 7,
                color: [255, 128, 0]};

function hash01Js(seed, i, k) {
  // The frozen contract recipe, in exact JS integers (BigInt
  // keeps the products exact, as Python's integers were).
  const M = 2147483648n;
  let x = (BigInt(seed) * 1103515245n + BigInt(i) * 12345n +
           BigInt(k) * 67890n) % M;
  x = (x * 1103515245n + 12345n) % M;
  return Number(x) / MOD;
}

function stateJs(sys, i, t) {
  // The frozen contract state formula, computed in JS.
  const life = sys.life;
  const count = sys.count;
  const speed = sys.speed;
  const spread = sys.spread !== undefined ? sys.spread : 0.5;
  const gravity = sys.gravity !== undefined ? sys.gravity : 0;
  const seed = sys.seed !== undefined ? sys.seed : 1;
  const age = ((t + i * (life / count)) % life + life) % life;
  const h0 = hash01Js(seed, i, 0);
  const h1 = hash01Js(seed, i, 1);
  const h2 = hash01Js(seed, i, 2);
  const vel = [
    (h0 - 0.5) * 2 * spread * speed,
    speed * (0.5 + 0.5 * h1),
    (h2 - 0.5) * 2 * spread * speed,
  ];
  const pos = [
    sys.origin[0] + vel[0] * age,
    sys.origin[1] + vel[1] * age - 0.5 * gravity * age * age,
    sys.origin[2] + vel[2] * age,
  ];
  return [pos, 1 - age / life];
}

test('test_file_exists_and_within_size_budget', () => {
  assert.ok(fs.existsSync(JS_PATH) && fs.statSync(JS_PATH).isFile(),
            JS_PATH);
  const size = fs.statSync(JS_PATH).size;
  assert.ok(size <= MAX_BYTES,
            `f3d-particles.js is ${size} B, budget is ${MAX_BYTES} B`);
});

test('test_exports', () => {
  needP();
  for (const k of ['hash01', 'state', 'positions', 'quad'])
    assert.ok(P[k] !== undefined, 'missing export ' + k);
  assert.strictEqual(window.F3DParticles, P);
});

test('test_hash01_matches_contract_recipe', () => {
  needP();
  // Both sides derive from the same integers and the value is
  // the rational x / 2^31, so they must agree to 1e-15 (the JS
  // side computes the second multiply exactly, in split parts,
  // because x * 1103515245 overflows the 2^53 exact range).
  const cases = [[1, 0, 0], [1, 0, 1], [1, 0, 2], [0, 0, 0],
                 [42, 7, 1], [7, 3, 2], [100000, 999, 2]];
  for (const [s, i, k] of cases) {
    assert.ok(near(P.hash01(s, i, k), hash01Js(s, i, k), 1e-15),
      `hash01(${s},${i},${k})=` + P.hash01(s, i, k));
  }
  for (let n = 0; n < 50; n++) {
    const u = P.hash01(3, n, n % 3);
    assert.ok(u >= 0 && u < 1, 'range: ' + u); }
});

test('test_state_at_t0_i0_is_origin_full_scale', () => {
  needP();
  const st = P.state(SYS_JS, 0, 0);
  assert.deepStrictEqual(st.pos, [1, 2, 3]);
  assert.strictEqual(st.scale, 1);
});

test('test_state_matches_python_contract', () => {
  needP();
  // (Named for the Python original: the contract reference is
  // stateJs above, translated from state_py.)
  const [pos, scale] = stateJs(SYS, 3, 0.7);
  const st = P.state(SYS_JS, 3, 0.7);
  st.pos.forEach((v, j) => assert.ok(
    near(v, pos[j], 1e-9),
    'pos[' + j + ']=' + v));
  assert.ok(near(st.scale, scale, 1e-9), 'scale=' + st.scale);
});

test('test_defaults_spread_gravity_seed', () => {
  needP();
  // Omitting spread / gravity / seed must behave exactly like
  // the frozen defaults spread 0.5, gravity 0, seed 1.
  const bare = {origin: [0, 0, 0], count: 4, life: 1.5, speed: 2,
    size: 1, color: [9, 9, 9]};
  const full = {origin: [0, 0, 0], count: 4, life: 1.5, speed: 2,
    size: 1, spread: 0.5, gravity: 0, seed: 1, color: [9, 9, 9]};
  assert.deepStrictEqual(P.state(bare, 2, 0.4),
    P.state(full, 2, 0.4));
  assert.deepStrictEqual(P.positions(bare, 0.4),
    P.positions(full, 0.4));
});

test('test_determinism', () => {
  needP();
  assert.deepStrictEqual(P.state(SYS_JS, 5, 1.25),
    P.state(SYS_JS, 5, 1.25));
  assert.deepStrictEqual(P.positions(SYS_JS, 1.25),
    P.positions(SYS_JS, 1.25));
  assert.deepStrictEqual(P.quad(SYS_JS, 5, 1.25, [4, 5, 6]),
    P.quad(SYS_JS, 5, 1.25, [4, 5, 6]));
});

test('test_positions_count', () => {
  needP();
  const all = P.positions(SYS_JS, 0.3);
  assert.strictEqual(all.length, 10);
  all.forEach((st, i) => assert.deepStrictEqual(st,
    P.state(SYS_JS, i, 0.3)));
  assert.deepStrictEqual(P.positions({origin: [0, 0, 0],
    count: 0, life: 1, speed: 1, size: 1}, 0.3), []);
});

test('test_quad_corner_distance', () => {
  needP();
  // Every corner sits size*scale*sqrt(2)/2 from the particle
  // centre, and adjacent corners are exactly size*scale apart.
  const [pos, scale] = stateJs(SYS, 2, 0.9);
  const want = SYS.size * scale * Math.sqrt(2) / 2;
  const sys = SYS_JS;
  const st = P.state(sys, 2, 0.9);
  const q = P.quad(sys, 2, 0.9, [10, 3, -4]);
  assert.strictEqual(q.length, 4);
  q.forEach((c) => {
    const d = Math.hypot(c[0] - st.pos[0], c[1] - st.pos[1],
      c[2] - st.pos[2]);
    assert.ok(near(d, want, 1e-9), 'corner dist=' + d); });
  for (let j = 0; j < 4; j++) {
    const a = q[j], b = q[(j + 1) % 4];
    const e = Math.hypot(a[0] - b[0], a[1] - b[1], a[2] - b[2]);
    assert.ok(near(e, SYS.size * scale, 1e-9), 'edge=' + e); }
  // Camera looking straight down -y at the particle: the
  // |dot| > 0.999 up-hint switch must still give a finite,
  // correctly-sized quad.
  const q2 = P.quad(sys, 2, 0.9,
    [st.pos[0], st.pos[1] + 5, st.pos[2]]);
  q2.forEach((c) => {
    const d = Math.hypot(c[0] - st.pos[0], c[1] - st.pos[1],
      c[2] - st.pos[2]);
    assert.ok(near(d, want, 1e-9), 'down-view dist=' + d); });
});

(async () => {
  let failures = 0;
  for (const [name, fn] of tests) {
    try { await fn(); }
    catch (e) {
      failures++;
      console.error('FAIL ' + name + ': ' + (e && e.stack || e));
    }
  }
  if (failures) {
    console.error(path.basename(__filename) + ': FAIL (' +
                  failures + ' of ' + tests.length + ' tests failed)');
    process.exit(1);
  }
  console.log(path.basename(__filename) + ': PASS (' + tests.length +
              ' tests)');
})();
