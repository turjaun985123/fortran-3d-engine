'use strict';
/* Port of test_f3d_env_js.py (Forge3D Wave A seat B60) to plain
 * Node.js: numeric tests for runtime/f3d-env.js.
 *
 * The JS sidecar mirrors the frozen Fortran formulas in src/fog.f90
 * and src/tonemapping.f90:
 *
 *     linear fog amount   clamp((dist-near)/(far-near), 0, 1)
 *     exp2 fog amount     1 - exp(-(density*dist)^2)
 *     view distance       (2*near*far) / (far+near - z*(far-near))
 *     Reinhard            y/(1+y),  y = x*exposure
 *     ACES (Narkowicz)    clamp((y*(2.51y+0.03)) /
 *                               (y*(2.43y+0.59)+0.14), 0, 1)
 *     none                clamp(x, 0, 1), exposure ignored
 *
 * Standalone-runnable:
 *
 *     node tests/compiler/test_f3d_env_js.js
 *
 * File existence and the <= 6,144-byte budget are always asserted.
 * The numeric assertions run the real JS in-process (the Python
 * original shelled out to `node -e`).
 */
const assert = require('assert');
const fs = require('fs');
const path = require('path');

const REPO_ROOT = path.join(__dirname, '..', '..');
const ENV_JS = path.join(REPO_ROOT, 'runtime', 'f3d-env.js');
const MAX_BYTES = 6144;

const tests = [];
function test(name, fn) { tests.push([name, fn]); }

test('test_file_exists', () => {
  assert.ok(fs.existsSync(ENV_JS) && fs.statSync(ENV_JS).isFile(),
            'runtime/f3d-env.js is missing');
});

test('test_size_within_budget', () => {
  assert.ok(fs.existsSync(ENV_JS) && fs.statSync(ENV_JS).isFile(),
            'runtime/f3d-env.js is missing');
  const size = fs.statSync(ENV_JS).size;
  assert.ok(size <= MAX_BYTES,
            `runtime/f3d-env.js is ${size} bytes, budget is ${MAX_BYTES}`);
});

test('test_header_names_mirrored_fortran_sources', () => {
  const text = fs.readFileSync(ENV_JS, 'utf8');
  assert.ok(text.includes('fog.f90'));
  assert.ok(text.includes('tonemapping.f90'));
  assert.ok(text.includes('F3DEnv'));
});

test('test_node_numeric_assertions', () => {
  // The Python NODE_SCRIPT, run in-process: argv[1] (the path to
  // f3d-env.js) becomes ENV_JS here.
  const E = require(ENV_JS);
  assert(E && typeof E === 'object', 'F3DEnv export missing');
  for (const name of ['fogFactorLinear', 'fogFactorExp2',
                      'viewDistanceFromNdc', 'applyFogPixel',
                      'tonemapScalar', 'tonemapPixel', 'fogPixel']) {
    assert.strictEqual(typeof E[name], 'function', name + ' missing');
  }
  const near = (a, b, tol, msg) =>
    assert(Math.abs(a - b) <= tol, msg + ': got ' + a + ', want ' + b);

  // Linear fog: the midpoint of [near, far] is exactly half fogged,
  // and the ends clamp to 0 / 1.
  assert.strictEqual(E.fogFactorLinear(15, 10, 20), 0.5);
  assert.strictEqual(E.fogFactorLinear(10, 10, 20), 0);
  assert.strictEqual(E.fogFactorLinear(99, 10, 20), 1);
  assert.strictEqual(E.fogFactorLinear(-5, 10, 20), 0);

  // Exp2 fog: no distance (or no density) means no fog; it grows
  // monotonically toward 1.
  assert.strictEqual(E.fogFactorExp2(0, 0.05), 0);
  assert.strictEqual(E.fogFactorExp2(10, 0), 0);
  assert(E.fogFactorExp2(50, 0.05) > E.fogFactorExp2(10, 0.05));
  assert(E.fogFactorExp2(1e6, 0.05) <= 1);

  // View distance: round-trip against the perspective z formula
  // z = (far+near - 2*near*far/d) / (far-near), the algebraic inverse
  // of viewDistanceFromNdc, for a sample depth.
  {
    const n = 0.1, f = 100, d = 10;
    const z = (f + n - 2 * n * f / d) / (f - n);
    near(E.viewDistanceFromNdc(z, n, f), d, 1e-9, 'viewDistance round-trip');
    near(E.viewDistanceFromNdc(1, n, f), f, 1e-9, 'z=1 is the far plane');
    near(E.viewDistanceFromNdc(-1, n, f), n, 1e-9, 'z=-1 is the near plane');
  }

  // Tonemapping: Reinhard(1) = 0.5 at exposure 1; exposure scales the
  // input first (Reinhard(0.5, exposure 2) is also 0.5).
  near(E.tonemapScalar('reinhard', 1, 1), 0.5, 1e-12, 'Reinhard(1)');
  near(E.tonemapScalar('reinhard', 0.5, 2), 0.5, 1e-12,
       'Reinhard exposure');

  // ACES(1) at exposure 1 lands in the known Narkowicz range.
  {
    const aces1 = E.tonemapScalar('aces', 1, 1);
    assert(aces1 > 0.7 && aces1 < 0.85, 'ACES(1) out of range: ' + aces1);
    assert.strictEqual(E.tonemapScalar('aces', 0, 1), 0);
  }

  // 'none' is the identity on 0..1 and ignores exposure entirely,
  // scalar- and pixel-wise.
  assert.strictEqual(E.tonemapScalar('none', 0.37, 99), 0.37);
  assert.strictEqual(E.tonemapScalar('none', 2, 1), 1);
  assert.deepStrictEqual(E.tonemapPixel([12, 200, 255], 'none', 5),
                         [12, 200, 255]);
  // Reinhard pixel: 255 -> 0.5 -> 128 (rounded).
  assert.deepStrictEqual(E.tonemapPixel([255, 255, 255], 'reinhard', 1),
                         [128, 128, 128]);

  // Fog blending: f=0 keeps the pixel, f=1 gives the fog colour.
  assert.deepStrictEqual(E.applyFogPixel([10, 20, 30], [200, 210, 220], 0),
                         [10, 20, 30]);
  assert.deepStrictEqual(E.applyFogPixel([10, 20, 30], [200, 210, 220], 1),
                         [200, 210, 220]);

  // fogPixel helper, true-distance input (cam omitted): a pixel far
  // beyond the linear fog range comes out (approximately) the fog
  // colour; a pixel at the near plane is untouched.
  {
    const spec = {mode: 'linear', near: 10, far: 100,
                  color: [200, 210, 220]};
    const farPx = E.fogPixel([10, 20, 30], 1000, spec, null);
    farPx.forEach((c, i) =>
      near(c, spec.color[i], 1, 'fogPixel far channel ' + i));
    assert.deepStrictEqual(E.fogPixel([10, 20, 30], 10, spec, null),
                           [10, 20, 30]);
    // 'none' mode and exp2 at distance 0 also leave the pixel alone.
    assert.deepStrictEqual(
      E.fogPixel([10, 20, 30], 1000, {mode: 'none', color: [0, 0, 0]}),
      [10, 20, 30]);
    assert.deepStrictEqual(
      E.fogPixel([10, 20, 30], 0,
                 {mode: 'exp2', density: 0.5, color: [200, 210, 220]}),
      [10, 20, 30]);
  }

  // fogPixel helper, NDC-z input (cam.isNdc): z=1 is the far plane, so
  // with fog far == camera far the pixel is fully fogged; the same z
  // read as a true distance would barely fog at all, which proves the
  // flag -- not the value's magnitude -- selects the interpretation.
  {
    const spec = {mode: 'linear', near: 0.1, far: 100,
                  color: [200, 210, 220]};
    const cam = {near: 0.1, far: 100, isNdc: true};
    assert.deepStrictEqual(E.fogPixel([10, 20, 30], 1, spec, cam),
                           [200, 210, 220]);
    // Same value 1 read as a true distance: factor (1-0.1)/(100-0.1)
    // is ~0.009, so the pixel stays within 2 of the original.
    const asDist = E.fogPixel([10, 20, 30], 1, spec,
                              {near: 0.1, far: 100});
    asDist.forEach((c, i) =>
      near(c, [10, 20, 30][i], 2, 'fogPixel distance channel ' + i));
  }

  console.log('F3D-ENV-JS NUMERIC OK');
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
