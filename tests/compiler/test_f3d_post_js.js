'use strict';
/* Port of test_f3d_post_js.py (Forge3D Wave C seat B76) to plain
 * Node.js: tests for the post-processing sidecar
 * runtime/f3d-post.js (MASTER-PLAN parity row 30), the JS mirror
 * of src/postprocess.f90 (seat B75).
 *
 * Standalone-runnable:
 *
 *     node tests/compiler/test_f3d_post_js.js
 *
 * The size/existence checks always run. The numeric checks load
 * the sidecar in-process (the Python original shelled out to
 * `node -e` snippets).
 *
 * The expected pixel values are computed in JS directly from
 * the filter formulas in the sidecar header / Fortran spec
 * (never copied from the sidecar output), so the two
 * implementations cross-check each other. Rounding mirrors JS
 * Math.round (half up, via floor(v + 0.5)), NOT Python's
 * banker's round.
 */
const assert = require('assert');
const fs = require('fs');
const path = require('path');

const REPO = path.join(__dirname, '..', '..');
const JS_PATH = path.join(REPO, 'runtime', 'f3d-post.js');
const MAX_BYTES = 6656; // re-pinned 2026-11-23 (v3.0 verification): 6433 B after the Phase 7 ES-module conversion (export block + compatibility footer + module header; no logic growth)

const tests = [];
function test(name, fn) { tests.push([name, fn]); }

// The Python PREAMBLE: expose `window` and bind the export as `P`.
let P = null;
let loadError = null;
try {
  global.window = globalThis;
  require(JS_PATH);
  P = globalThis.F3DPost;
} catch (e) { loadError = e; }
function needP() {
  if (loadError) throw loadError;
  return P;
}

// A varied 3x3 RGB image (row-major triplets).
const IMG3 = [
  255, 0, 0,     0, 255, 0,     0, 0, 255,
  10, 20, 30,    100, 110, 120, 200, 210, 220,
  50, 60, 70,    80, 90, 100,   130, 140, 150,
];
const W3 = 3, H3 = 3;

function checkApply(pixels, w, h, chain, expected, stride) {
  // Assert sidecar apply() on `pixels` yields exactly `expected`.
  // (The Python original's `stride` argument was accepted but not
  // passed into its node snippet; it is kept here for parity.)
  needP();
  const px = new Uint8ClampedArray([...pixels]);
  const out = P.apply(px, w, h, chain);
  assert.strictEqual(out, px, 'apply must return its input');
  assert.deepStrictEqual(Array.from(px), [...expected]);
}

// --- JS mirror of the spec (independent of the sidecar) -----------

function fix(v) {
  // JS Math.round (half up) then clamp to 0..255.
  return Math.max(0, Math.min(255, Math.floor(v + 0.5)));
}

function lum(r, g, b) {
  return 0.299 * r + 0.587 * g + 0.114 * b;
}

function blurPass(px, w, h) {
  const src = [...px];
  for (let y = 0; y < h; y++) {
    for (let x = 0; x < w; x++) {
      for (let c = 0; c < 3; c++) {
        let total = 0.0;
        for (const dy of [-1, 0, 1]) {
          const yy = Math.min(h - 1, Math.max(0, y + dy));
          for (const dx of [-1, 0, 1]) {
            const xx = Math.min(w - 1, Math.max(0, x + dx));
            total += src[(yy * w + xx) * 3 + c];
          }
        }
        px[(y * w + x) * 3 + c] = total / 9;
      }
    }
  }
}

function applyJs(pixels, w, h, chain) {
  // The filter spec, in JS, on an RGB triplet list.
  let px = pixels.map(v => Number(v));
  for (const step of chain) {
    const name = step.name.toLowerCase();  // names are case-insensitive
    const amount = step.amount !== undefined ? step.amount : 1;
    if (name === 'blur') {
      // Math.trunc mirrors Python int() truncation toward zero.
      for (let n = 0; n < Math.max(0, Math.trunc(amount)); n++) {
        blurPass(px, w, h);
        px = px.map(v => Number(fix(v)));
      }
    } else if (name === 'bloom') {
      for (let i = 0; i < px.length; i += 3) {
        const add = Math.max(0.0, lum(px[i], px[i + 1], px[i + 2]) / 255
                             - 0.75) * amount * 255;
        px[i] += add;
        px[i + 1] += add;
        px[i + 2] += add;
      }
    } else if (name === 'vignette') {
      for (let y = 0; y < h; y++) {
        const ny = h > 1 ? 2 * y / (h - 1) - 1 : 0.0;
        for (let x = 0; x < w; x++) {
          const nx = w > 1 ? 2 * x / (w - 1) - 1 : 0.0;
          const s = 1 - amount * (nx * nx + ny * ny) / 2;
          const i = (y * w + x) * 3;
          px[i] *= s;
          px[i + 1] *= s;
          px[i + 2] *= s;
        }
      }
    } else if (name === 'gamma') {
      if (amount > 0) {
        px = px.map(v => 255 * (v / 255) ** (1 / amount));
      }
    } else if (name === 'grayscale') {
      const a = Math.min(1.0, Math.max(0.0, amount));
      for (let i = 0; i < px.length; i += 3) {
        const grey = lum(px[i], px[i + 1], px[i + 2]);
        for (let c = 0; c < 3; c++) {
          px[i + c] = (1 - a) * px[i + c] + a * grey;
        }
      }
    } else if (name === 'sepia') {
      const a = Math.min(1.0, Math.max(0.0, amount));
      for (let i = 0; i < px.length; i += 3) {
        const r = px[i], g = px[i + 1], b = px[i + 2];
        const target = [
          Math.min(255.0, 0.393 * r + 0.769 * g + 0.189 * b),
          Math.min(255.0, 0.349 * r + 0.686 * g + 0.168 * b),
          Math.min(255.0, 0.272 * r + 0.534 * g + 0.131 * b),
        ];
        const orig = [r, g, b];
        for (let c = 0; c < 3; c++) {
          px[i + c] = (1 - a) * orig[c] + a * target[c];
        }
      }
    }
    // Unknown names: no-op, mirroring the Fortran.
    px = px.map(v => Number(fix(v)));
  }
  return px.map(v => fix(v));
}

test('test_file_exists_and_within_size_budget', () => {
  assert.ok(fs.existsSync(JS_PATH) && fs.statSync(JS_PATH).isFile(),
            JS_PATH);
  const size = fs.statSync(JS_PATH).size;
  assert.ok(size <= MAX_BYTES,
            `f3d-post.js is ${size} B, budget is ${MAX_BYTES} B`);
});

test('test_exports', () => {
  needP();
  assert.strictEqual(typeof P.apply, 'function');
  assert.strictEqual(window.F3DPost, P);
});

test('test_blur_one_pass', () => {
  const chain = [{name: 'blur', amount: 1}];
  checkApply(IMG3, W3, H3, chain, applyJs(IMG3, W3, H3, chain));
});

test('test_blur_pass_count_and_truncation', () => {
  // amount 2 = two passes; 1.9 truncates to one pass (int());
  // 0 passes is a no-op.
  const two = [{name: 'blur', amount: 2}];
  checkApply(IMG3, W3, H3, two, applyJs(IMG3, W3, H3, two));
  const frac = [{name: 'blur', amount: 1.9}];
  const one = [{name: 'blur', amount: 1}];
  checkApply(IMG3, W3, H3, frac, applyJs(IMG3, W3, H3, one));
  const zero = [{name: 'blur', amount: 0}];
  checkApply(IMG3, W3, H3, zero, IMG3);
});

test('test_bloom_threshold_and_amount', () => {
  // First pixel is above the 0.75 luminance threshold, the
  // second is below it and must stay untouched.
  const img = [200, 200, 200, 100, 50, 20];
  for (const amount of [1, 2.5]) {
    const chain = [{name: 'bloom', amount: amount}];
    checkApply(img, 2, 1, chain, applyJs(img, 2, 1, chain));
  }
});

test('test_vignette', () => {
  const chain = [{name: 'vignette', amount: 0.6}];
  const expected = applyJs(IMG3, W3, H3, chain);
  // Centre pixel (index 1,1) has d2 = 0: unchanged by hand.
  assert.deepStrictEqual(expected.slice(12, 15), IMG3.slice(12, 15));
  checkApply(IMG3, W3, H3, chain, expected);
});

test('test_gamma', () => {
  const img = [0, 64, 255, 16, 128, 200];
  for (const amount of [2.0, 0.5]) {
    const chain = [{name: 'gamma', amount: amount}];
    checkApply(img, 2, 1, chain, applyJs(img, 2, 1, chain));
  }
});

test('test_grayscale_full_and_partial', () => {
  for (const amount of [1, 0.5, 0]) {
    const chain = [{name: 'grayscale', amount: amount}];
    checkApply(IMG3, W3, H3, chain,
               applyJs(IMG3, W3, H3, chain));
  }
});

test('test_sepia_full_and_partial', () => {
  for (const amount of [1, 0.4]) {
    const chain = [{name: 'sepia', amount: amount}];
    checkApply(IMG3, W3, H3, chain,
               applyJs(IMG3, W3, H3, chain));
  }
});

test('test_amount_clamping_and_gamma_guard', () => {
  // grayscale / sepia blend factors clamp to [0, 1] in the
  // Fortran, so amount 2 behaves as 1 and -1 as 0 (a no-op);
  // gamma with amount <= 0 is a no-op.
  for (const name of ['grayscale', 'sepia']) {
    const over = [{name: name, amount: 2}];
    const full = [{name: name, amount: 1}];
    checkApply(IMG3, W3, H3, over,
               applyJs(IMG3, W3, H3, full));
    const under = [{name: name, amount: -1}];
    checkApply(IMG3, W3, H3, under, IMG3);
  }
  for (const amount of [0, -2.0]) {
    const chain = [{name: 'gamma', amount: amount}];
    checkApply(IMG3, W3, H3, chain, IMG3);
  }
});

test('test_filter_names_case_insensitive', () => {
  const chain = [{name: 'GrAyScAlE', amount: 1},
                 {name: 'GAMMA', amount: 2.0}];
  checkApply(IMG3, W3, H3, chain, applyJs(IMG3, W3, H3, chain));
});

test('test_missing_amount_defaults_to_one', () => {
  const bare = [{name: 'grayscale'}];
  const full = [{name: 'grayscale', amount: 1}];
  checkApply(IMG3, W3, H3, bare, applyJs(IMG3, W3, H3, full));
});

test('test_chain_order_sensitivity', () => {
  // gamma-then-grayscale must differ from grayscale-then-gamma
  // (both expectations derived in JS; sanity-checked to
  // actually differ before the sidecar is asked to match them).
  const img = [200, 30, 60];
  const fwd = [{name: 'gamma', amount: 2.0},
               {name: 'grayscale', amount: 1}];
  const rev = [{name: 'grayscale', amount: 1},
               {name: 'gamma', amount: 2.0}];
  const expFwd = applyJs(img, 1, 1, fwd);
  const expRev = applyJs(img, 1, 1, rev);
  assert.notDeepStrictEqual(expFwd, expRev);
  checkApply(img, 1, 1, fwd, expFwd);
  checkApply(img, 1, 1, rev, expRev);
});

test('test_chain_applies_sequentially', () => {
  const chain = [{name: 'blur', amount: 1},
                 {name: 'sepia', amount: 0.7},
                 {name: 'vignette', amount: 0.5}];
  checkApply(IMG3, W3, H3, chain, applyJs(IMG3, W3, H3, chain));
});

test('test_unknown_filter_is_noop', () => {
  const unknown = [{name: 'sharpen', amount: 5}];
  checkApply(IMG3, W3, H3, unknown, IMG3);
  // An unknown name in the middle of a chain must not disturb
  // the filters around it.
  const mixed = [{name: 'grayscale', amount: 1},
                 {name: 'nope', amount: 3},
                 {name: 'gamma', amount: 2.0}];
  const plain = [mixed[0], mixed[2]];
  checkApply(IMG3, W3, H3, mixed, applyJs(IMG3, W3, H3, plain));
});

test('test_empty_chain_and_rgba_alpha_preserved', () => {
  checkApply(IMG3, W3, H3, [], IMG3);
  const rgba = [200, 30, 60, 77];
  const chain = [{name: 'grayscale', amount: 1}];
  const expected = applyJs(rgba.slice(0, 3), 1, 1, chain).concat([77]);
  checkApply(rgba, 1, 1, chain, expected, 4);
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
