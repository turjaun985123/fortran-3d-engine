'use strict';
/* Port of test_f3d_shader_js.py (Forge3D Wave E seat E04) to
 * plain Node.js: tests for the custom-shader sidecar
 * runtime/f3d-shader.js (RPN shader expressions, mirroring
 * src/shader.f90 -- identical RPN, identical results).
 *
 * Standalone-runnable:
 *
 *     node tests/compiler/test_f3d_shader_js.js
 *
 * The existence check always runs. The numeric checks load the
 * sidecar in-process (the Python original shelled out to
 * `node -e` snippets).
 *
 * The value grid is cross-checked independently in JS: every
 * expected value below is written as a plain JS / Math
 * expression (translated from the Python original, which used
 * the math module), not derived from the sidecar. Tolerance
 * is 1e-9. Two cross-language notes:
 *
 * * Modulo: Fortran MOD(a, b) and JS % both take the sign
 *   of the dividend (a); Python's % takes the sign of the
 *   divisor instead, so the negative-modulo expectations use
 *   fmod (which also takes the sign of the dividend).
 * * Byte rounding: JS Math.round is half-up, Fortran nint
 *   is half-to-even. Test values avoid exact .5 boundaries
 *   EXCEPT the documented 0.5 case: 0.5 * 255 = 127.5, and
 *   both agree there -- nint(127.5) = 128 (127.5 rounds to
 *   the even 128) and Math.round(127.5) = 128.
 */
const assert = require('assert');
const fs = require('fs');
const path = require('path');

const REPO = path.join(__dirname, '..', '..');
const JS_PATH = path.join(REPO, 'runtime', 'f3d-shader.js');

const tests = [];
function test(name, fn) { tests.push([name, fn]); }

// The Python PREAMBLE: expose `window` and bind the export as `S`,
// plus the near helper.
let S = null;
let loadError = null;
try {
  global.window = globalThis;
  require(JS_PATH);
  S = globalThis.Forge3DShader;
} catch (e) { loadError = e; }
function needS() {
  if (loadError) throw loadError;
  return S;
}
const near = (a, b, e) => Math.abs(a - b) <= (e || 1e-9);
// C/Python math.fmod: truncated (sign-of-dividend) remainder.
const fmod = (a, b) => a - b * Math.trunc(a / b);

function env(overrides) {
  const base = {c: 0.6, r: 0.2, g: 0.4, b: 0.8, x: 0.35, y: -1.25,
                z: 2.0, u: 0.25, v: 0.75, ndl: 0.8, t: 1.5};
  return Object.assign(base, overrides || {});
}

// [rpn, env, expected] -- expected computed independently here
// with Math / plain JS arithmetic.
const CASES = [
  // Constants and literal forms (string and numeric tokens).
  [['0.5'], env(), 0.5],
  [[0.5], env(), 0.5],
  [[42], env(), 42.0],
  [['-3.25'], env(), -3.25],
  [['pi'], env(), Math.PI],
  [['pi', '2', '/'], env(), Math.PI / 2],
  // Every variable.
  [['c'], env(), 0.6],
  [['r', 'g', '+', 'b', '+'], env(), 0.2 + 0.4 + 0.8],
  [['x', 'y', '+', 'z', '+'], env(), 0.35 + -1.25 + 2.0],
  [['u', 'v', '*'], env(), 0.25 * 0.75],
  [['ndl'], env(), 0.8],
  [['t'], env(), 1.5],
  // Binary operators and neg.
  [['3', '4', '+'], env(), 3 + 4],
  [['3', '4', '-'], env(), 3 - 4],
  [['3', '4', '*'], env(), 3 * 4],
  [['7', '2', '/'], env(), 7 / 2],
  [['7', '3', '%'], env(), fmod(7, 3)],
  [['9', '0.5', '^'], env(), Math.pow(9, 0.5)],
  [['5', 'neg'], env(), -5.0],
  [['x', 'neg'], env(), -0.35],
  // Lighting expression: c * (0.25 + 0.75 * ndl).
  [['c', '0.25', '0.75', 'ndl', '*', '+', '*'], env(),
   0.6 * (0.25 + 0.75 * 0.8)],
  [['c', '0.25', '0.75', 'ndl', '*', '+', '*'], env({ndl: 0.0}),
   0.6 * 0.25],
  [['c', '0.25', '0.75', 'ndl', '*', '+', '*'], env({ndl: 1.0}),
   0.6 * 1.0],
  // Checker expression c * step(0.5, fract(x * 2)): fract(0.2)
  // is below the edge (gives 0), fract(0.8) is above (gives c).
  [['c', '0.5', 'x', '2', '*', 'fract', 'step', '*'],
   env({x: 0.1}), 0.6 * ((0.1 * 2 - Math.floor(0.1 * 2)) >= 0.5
                         ? 1.0 : 0.0)],
  [['c', '0.5', 'x', '2', '*', 'fract', 'step', '*'],
   env({x: 0.4}), 0.6 * ((0.4 * 2 - Math.floor(0.4 * 2)) >= 0.5
                         ? 1.0 : 0.0)],
  // Every 1-arg function.
  [['1', 'sin'], env(), Math.sin(1)],
  [['1', 'cos'], env(), Math.cos(1)],
  [['0.5', 'tan'], env(), Math.tan(0.5)],
  [['y', 'abs'], env(), Math.abs(-1.25)],
  [['2', 'sqrt'], env(), Math.sqrt(2)],
  [['1.7', 'floor'], env(), Math.floor(1.7)],
  [['-1.7', 'floor'], env(), Math.floor(-1.7)],
  [['1.2', 'ceil'], env(), Math.ceil(1.2)],
  [['-1.2', 'ceil'], env(), Math.ceil(-1.2)],
  [['2.75', 'fract'], env(), 2.75 - Math.floor(2.75)],
  [['-1.25', 'fract'], env(), -1.25 - Math.floor(-1.25)],
  // Every 2-arg function.
  [['3', '7', 'min'], env(), Math.min(3, 7)],
  [['3', '7', 'max'], env(), Math.max(3, 7)],
  [['0.5', '0.5', 'step'], env(), 1.0],   // x == edge -> 1
  [['0.5', '0.25', 'step'], env(), 0.0],  // x < edge -> 0
  [['2', '10', 'pow'], env(), Math.pow(2, 10)],
  [['5', '3', 'pow'], env(), Math.pow(5, 3)],
  // Every 3-arg function.
  [['1.5', '0', '1', 'clamp'], env(), Math.min(Math.max(1.5, 0), 1)],
  [['-0.5', '0', '1', 'clamp'], env(), Math.min(Math.max(-0.5, 0), 1)],
  [['0.3', '0', '1', 'clamp'], env(), 0.3],
  [['0', '10', '0.25', 'mix'], env(), 0 + (10 - 0) * 0.25],
  [['c', '1', 'ndl', 'mix'], env(), 0.6 + (1 - 0.6) * 0.8],
  // Semantics guards.
  [['1', '0', '/'], env(), 0.0],          // div by zero -> 0
  [['c', '0', '/'], env(), 0.0],
  [['1', '0', '%'], env(), 0.0],          // mod by zero -> 0
  // Negative modulo: JS % / Fortran MOD take the sign of the
  // dividend, so -7 mod 3 is -1 (Python's % would give 2;
  // math.fmod matches the Fortran/JS convention).
  [['-7', '3', '%'], env(), fmod(-7, 3)],
  [['7', '-3', '%'], env(), fmod(7, -3)],
  [['-2', '0.5', 'pow'], env(), 0.0],     // neg base, frac exp
  [['0', '-1', 'pow'], env(), 0.0],       // 0 ^ negative -> 0
  [['0', '0', 'pow'], env(), 1.0],        // 0^0 = 1
  [['0', '0', '^'], env(), 1.0],
  [['-4', 'sqrt'], env(), 0.0],           // sqrt(negative) -> 0
  [['-8', '0.5', '^'], env(), 0.0],       // ^ shares pow guard
  // A composed expression using several pieces at once.
  [['x', 'fract', 'y', 'abs', 'min', 't', '*'], env(),
   Math.min(0.35 - Math.floor(0.35), Math.abs(-1.25)) * 1.5],
];

test('test_file_exists', () => {
  assert.ok(fs.existsSync(JS_PATH) && fs.statSync(JS_PATH).isFile(),
            JS_PATH);
  assert.ok(fs.statSync(JS_PATH).size > 0);
});

test('test_exports', () => {
  needS();
  for (const k of ['parseRPN', 'evalRPN', 'shadeChannel',
                   'shadeRGB'])
    assert.strictEqual(typeof S[k], 'function',
      'missing export ' + k);
  assert.strictEqual(window.Forge3DShader, S);
});

test('test_parse_returns_validated_copy', () => {
  needS();
  const inp = ['c', '0.5', '+'];
  const out = S.parseRPN(inp);
  assert.deepStrictEqual(out, inp);
  assert.notStrictEqual(out, inp);
  assert.deepStrictEqual(S.parseRPN([0.25, 'pi', '*']),
    [0.25, 'pi', '*']);
});

test('test_value_grid_cross_check', () => {
  needS();
  // The Python original shipped the cases to one node process
  // via an env var and compared the returned JSON array; here
  // the evaluation happens in-process with the same comparison.
  const got = CASES.map(([rpn, e]) => S.evalRPN(rpn, e));
  assert.strictEqual(got.length, CASES.length);
  CASES.forEach(([rpn, , expected], i) => {
    const actual = got[i];
    assert.ok(Math.abs(actual - expected) <= 1e-9,
      `case ${i} rpn=${JSON.stringify(rpn)}: js=${actual} ` +
      `expected=${expected}`);
  });
});

test('test_shade_channel', () => {
  needS();
  // 0.5 * 255 = 127.5 -> 128 (see module docstring:
  // JS Math.round half-up and Fortran nint half-to-even
  // agree on this value). Out-of-range clamps first.
  assert.strictEqual(S.shadeChannel(['0.5'], {}), 128);
  assert.strictEqual(S.shadeChannel(['0'], {}), 0);
  assert.strictEqual(S.shadeChannel(['1'], {}), 255);
  assert.strictEqual(S.shadeChannel(['2'], {}), 255);
  assert.strictEqual(S.shadeChannel(['-1'], {}), 0);
  assert.strictEqual(S.shadeChannel(['c'], {c: 0.25}), 64);
});

test('test_shade_rgb', () => {
  needS();
  // Constant 0.5 -> 128 on every channel (127.5 case,
  // documented above; both roundings agree).
  assert.deepStrictEqual(S.shadeRGB(['0.5'], [10, 20, 30], {}),
    [128, 128, 128]);
  // c alone is the identity on the base colour.
  assert.deepStrictEqual(S.shadeRGB(['c'], [10, 20, 30], {}),
    [10, 20, 30]);
  // r is the base red for every channel: 10/255 -> 10.
  assert.deepStrictEqual(S.shadeRGB(['r'], [10, 20, 30], {}),
    [10, 10, 10]);
  // Lighting expr at ndl = 1 is also the identity;
  // at ndl = 0 it scales c by 0.25: 200*.25=50,
  // 100*.25=25, 40*.25=10 (no .5 byte boundaries).
  const lit = ['c', '0.25', '0.75', 'ndl', '*', '+', '*'];
  assert.deepStrictEqual(
    S.shadeRGB(lit, [200, 100, 40], {ndl: 1}),
    [200, 100, 40]);
  assert.deepStrictEqual(
    S.shadeRGB(lit, [200, 100, 40], {ndl: 0}),
    [50, 25, 10]);
  // Clamping through shadeRGB.
  assert.deepStrictEqual(S.shadeRGB(['2'], [0, 0, 0], {}),
    [255, 255, 255]);
});

test('test_parse_errors_throw', () => {
  needS();
  const bad = [
    [['foo'], /unknown/],           // unknown variable
    [['c', 'bogus', '+'], /unknown/],  // unknown token
    [['nosuchfn'], /unknown/],      // unknown function
    [['+'], /underflow/],           // arity underflow
    [['c', '+'], /underflow/],
    [['1', '2', 'clamp'], /underflow/],  // 3-arg, 2 given
    [['sin'], /underflow/],
    [['c', 'r'], /leftover/],       // leftover stack 2
    [[], /leftover/],               // leftover stack 0
    ['not-an-array', /array/],
  ];
  for (const [rpn, re] of bad) {
    assert.throws(() => S.parseRPN(rpn), re,
      'parseRPN(' + JSON.stringify(rpn) + ')');
  }
  // evalRPN validates too.
  assert.throws(() => S.evalRPN(['wat'], {}), /unknown/);
  assert.throws(() => S.evalRPN(['c', 'r'], {}), /leftover/);
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
