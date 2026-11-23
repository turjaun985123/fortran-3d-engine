// Forge3D module "f3d-post" - OPTIONAL post-processing sidecar.
// Role: a chain of screen-space filters applied, in order, to a
// finished frame; JS mirror of the post-processing filters in
// src/postprocess.f90 (MASTER-PLAN parity row 30, seat B75).
// ES module (Phase 7): the public API is the named export below.
// No sibling-runtime imports: this module uses no helpers from
// runtime/f3d.js (core) and defines everything it needs locally.
// The classic bundle is built from these ES modules via
// tools/build_runtime.mjs; the compatibility footer at the end
// attaches the exported names onto globalThis.F3D for
// classic-bundle / legacy-global consumers.
//
// Pixel layout: `pixels` is a Uint8ClampedArray of RGB triplets,
// 3*w*h entries, row-major, top row first. A 4*w*h RGBA buffer is
// also accepted: its RGB channels are filtered and alpha is left
// untouched. `apply` filters IN PLACE and returns the same buffer.
//
// Chain: [{name, amount}, ...], applied in order; a missing amount
// defaults to 1. Filter names are case-insensitive. After EVERY
// filter the buffer is rounded to the nearest integer and clamped
// to 0..255 (as the Fortran framebuffer passes do), so the next
// filter reads integer pixels. An unknown filter name is a silent
// no-op, mirroring the Fortran.
//
// Filters (lum = 0.299*r + 0.587*g + 0.114*b, in 0..255 unless noted):
//   blur      3x3 box blur, one pass per int(amount) passes, only
//             when amount >= 1; each pass averages the 9 neighbours
//             with edge coordinates clamped to the image. (The
//             Fortran computes (sum + 4) / 9 in integer division;
//             sum/9 rounded to nearest is identical, as a sum of 9
//             integers never lands exactly on a .5 fraction.)
//   bloom     excess = max(0, lum/255 - 0.75) * amount, added to
//             every channel as excess*255.
//   vignette  channel *= 1 - amount*d2, where nx = 2*x/(w-1) - 1
//             (0 when w == 1), ny likewise, and
//             d2 = (nx*nx + ny*ny) / 2 -- 0 at the centre, 1 at the
//             corners.
//   gamma     channel = 255 * (channel/255) ** (1/amount);
//             amount <= 0 is a no-op.
//   grayscale blend toward luminance with a = clamp(amount, 0, 1):
//             channel = (1-a)*channel + a*lum.
//   sepia     blend toward the sepia matrix result with
//             a = clamp(amount, 0, 1), the target first clamped to
//             255 (unrounded): matrix rows [0.393, 0.769, 0.189],
//             [0.349, 0.686, 0.168] and [0.272, 0.534, 0.131].
'use strict';

function lum(r, gg, b) { return 0.299 * r + 0.587 * gg + 0.114 * b; }
function fix(v) { return v < 0 ? 0 : (v > 255 ? 255 : Math.round(v)); }

// One 3x3 box-blur pass over the RGB work buffer, edges clamped.
function blurPass(wb, w, h) {
  var src = wb.slice(), x, y, c, dx, dy, xx, yy, sum;
  for (y = 0; y < h; y++) for (x = 0; x < w; x++) {
    for (c = 0; c < 3; c++) { sum = 0;
      for (dy = -1; dy <= 1; dy++) {
        yy = Math.min(h - 1, Math.max(0, y + dy));
        for (dx = -1; dx <= 1; dx++) {
          xx = Math.min(w - 1, Math.max(0, x + dx));
          sum += src[(yy * w + xx) * 3 + c];
        }
      }
      wb[(y * w + x) * 3 + c] = sum / 9;
    }
  }
}

var FILTERS = {
  blur: function (wb, w, h, amount) {
    var passes = Math.trunc(amount), p, i;
    for (p = 0; p < passes; p++) {
      blurPass(wb, w, h);
      for (i = 0; i < wb.length; i++) wb[i] = fix(wb[i]);
    }
  },
  bloom: function (wb, w, h, amount) {
    var i, add;
    for (i = 0; i < wb.length; i += 3) {
      add = Math.max(0, lum(wb[i], wb[i + 1], wb[i + 2]) / 255 - 0.75)
        * amount * 255;
      wb[i] += add; wb[i + 1] += add; wb[i + 2] += add;
    }
  },
  vignette: function (wb, w, h, amount) {
    var x, y, i, nx, ny, s;
    for (y = 0; y < h; y++) {
      ny = h > 1 ? 2 * y / (h - 1) - 1 : 0;
      for (x = 0; x < w; x++) {
        nx = w > 1 ? 2 * x / (w - 1) - 1 : 0;
        s = 1 - amount * (nx * nx + ny * ny) / 2;
        i = (y * w + x) * 3;
        wb[i] *= s; wb[i + 1] *= s; wb[i + 2] *= s;
      }
    }
  },
  gamma: function (wb, w, h, amount) {
    if (amount <= 0 || amount === 1) return;
    var i, e = 1 / amount;
    for (i = 0; i < wb.length; i++)
      wb[i] = 255 * Math.pow(wb[i] / 255, e);
  },
  grayscale: function (wb, w, h, amount) {
    var i, l, a = Math.min(1, Math.max(0, amount));
    if (a === 0) return;
    for (i = 0; i < wb.length; i += 3) {
      l = lum(wb[i], wb[i + 1], wb[i + 2]);
      wb[i] = (1 - a) * wb[i] + a * l;
      wb[i + 1] = (1 - a) * wb[i + 1] + a * l;
      wb[i + 2] = (1 - a) * wb[i + 2] + a * l;
    }
  },
  sepia: function (wb, w, h, amount) {
    var i, r, gg, b, a = Math.min(1, Math.max(0, amount));
    if (a === 0) return;
    for (i = 0; i < wb.length; i += 3) {
      r = wb[i]; gg = wb[i + 1]; b = wb[i + 2];
      wb[i] = (1 - a) * r + a
        * Math.min(255, 0.393 * r + 0.769 * gg + 0.189 * b);
      wb[i + 1] = (1 - a) * gg + a
        * Math.min(255, 0.349 * r + 0.686 * gg + 0.168 * b);
      wb[i + 2] = (1 - a) * b + a
        * Math.min(255, 0.272 * r + 0.534 * gg + 0.131 * b);
    }
  }
};

// Apply `chain` to `pixels` (see the header for the layout) in
// place; returns `pixels`. Unknown names are ignored.
function apply(pixels, w, h, chain) {
  if (!pixels || !chain || !chain.length || w <= 0 || h <= 0)
    return pixels;
  var n = w * h, stride = pixels.length === 4 * n ? 4 : 3, i, j;
  var wb = new Float64Array(n * 3);
  for (i = 0; i < n; i++) for (j = 0; j < 3; j++)
    wb[i * 3 + j] = pixels[i * stride + j];
  chain.forEach(function (step) {
    if (!step) return;
    var f = FILTERS[String(step.name).toLowerCase()];
    if (!f) return; // unknown filter: no-op, mirroring the Fortran
    f(wb, w, h, step.amount == null ? 1 : +step.amount);
    for (i = 0; i < wb.length; i++) wb[i] = fix(wb[i]);
  });
  for (i = 0; i < n; i++) for (j = 0; j < 3; j++)
    pixels[i * stride + j] = wb[i * 3 + j];
  return pixels;
}

export { apply };

// Compatibility footer (Phase 7): attach the exported names onto
// globalThis.F3D for classic-bundle / legacy-global consumers,
// and keep the historical globalThis.F3DPost alias unchanged.
var F3DPost = { apply: apply };
globalThis.F3D = globalThis.F3D || {};
globalThis.F3D.F3DPost = F3DPost;
globalThis.F3DPost = F3DPost;
if (typeof window !== 'undefined') window.F3DPost = F3DPost;
