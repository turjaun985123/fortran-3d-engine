// f3d-sprites-text -- Forge3D sprites + text module.
// Role: OPTIONAL sidecar, load AFTER runtime/f3d.js. Mirrors the
// Fortran modules src/sprite.f90 (billboards, MASTER-PLAN row 23)
// and src/text_render.f90 (5x7 bitmap text, row 29): 2D-in-3D
// overlay parity for the JS backend.
// ES module (Phase 7): the public names are declared as named
// exports below; a classic bundle is also produced via
// tools/build_runtime.mjs.
//
// FROZEN FONT REPRESENTATION: GLYPHS is an array of 43 glyphs, one
// per character of CHARSET, each glyph an array of 7 row values
// (0..31); in a row value, bit (4-col) set = pixel on, col 0 = left,
// row 0 = top. (The Fortran packs a glyph into one integer mask
// with bit (34-(row*5+col)); that exceeds JS 32-bit bitwise range,
// so the row-byte form is the JS representation.)
// NOTE: the GLYPHS table below matches src/text_render.f90
// GLYPH_MASKS exactly (each JS row array is derived from the
// Fortran integer mask for the same glyph index); the Wave B
// parity test cross-checks them against the Fortran.
// No sibling-runtime imports: this module uses no names from
// runtime/f3d.js or any other sidecar -- the vec helpers below
// (dot / sub / cross / norm / v3) are defined locally in this file.
function dot(a, b) { return a[0]*b[0] + a[1]*b[1] + a[2]*b[2]; }
function sub(a, b) { return [a[0]-b[0], a[1]-b[1], a[2]-b[2]]; }
function cross(a, b) { return [a[1]*b[2]-a[2]*b[1],
  a[2]*b[0]-a[0]*b[2], a[0]*b[1]-a[1]*b[0]]; }
function norm(a) { var l = Math.hypot(a[0], a[1], a[2]);
  return l > 1e-12 ? [a[0]/l, a[1]/l, a[2]/l] : [0, 0, 0]; }
function v3(v, d) { return v == null ? d.slice()
  : [+v[0] || 0, +v[1] || 0, +v[2] || 0]; }

// --- Sprites (billboards) -----------------------------------------
// view_dir = normalize(center - cam_pos); up_hint = (0,1,0), or
// (1,0,0) when |dot(view_dir, up_hint)| > 0.999 (looking straight
// up/down); right = normalize(cross(up_hint, view_dir));
// up = cross(view_dir, right). right/up are orthonormal and both
// perpendicular to view_dir.
function spriteBasis(center, camPos) {
  var vd = norm(sub(v3(center, [0, 0, 0]), v3(camPos, [0, 0, 0])));
  if (vd[0] === 0 && vd[1] === 0 && vd[2] === 0) vd = [0, 0, 1];
  var hint = Math.abs(dot(vd, [0, 1, 0])) > 0.999 ? [1, 0, 0] : [0, 1, 0];
  var right = norm(cross(hint, vd));
  var up = cross(vd, right);
  return { right: right, up: up };
}

// Quad corners, in the sprite.f90 order:
// [c - r - u, c + r - u, c + r + u, c - r + u], offsets scaled by
// size/2, so each corner is size/sqrt(2) from the centre and
// adjacent corners are `size` apart.
function spriteQuad(center, size, camPos) {
  var c = v3(center, [0, 0, 0]), b = spriteBasis(c, camPos),
      h = (size || 0) / 2, out = [], s, t, i;
  var signs = [[-1, -1], [1, -1], [1, 1], [-1, 1]];
  for (i = 0; i < 4; i++) { s = signs[i][0] * h; t = signs[i][1] * h;
    out.push([c[0] + b.right[0]*s + b.up[0]*t,
              c[1] + b.right[1]*s + b.up[1]*t,
              c[2] + b.right[2]*s + b.up[2]*t]); }
  return out;
}

// --- 5x7 bitmap text ----------------------------------------------
var CHARSET = " ABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789.!?-:'";
var GLYPHS = [
  [0,0,0,0,0,0,0],          // (space)
  [14,17,17,31,17,17,17],   // A
  [30,17,17,30,17,17,30],   // B
  [15,16,16,16,16,16,15],   // C
  [30,17,17,17,17,17,30],   // D
  [31,16,16,30,16,16,31],   // E
  [31,16,16,30,16,16,16],   // F
  [15,16,16,23,17,17,14],   // G
  [17,17,17,31,17,17,17],   // H
  [31,4,4,4,4,4,31],        // I
  [7,2,2,2,2,18,12],        // J
  [17,18,20,24,20,18,17],   // K
  [16,16,16,16,16,16,31],   // L
  [17,27,21,21,17,17,17],   // M
  [17,25,25,21,19,19,17],   // N
  [14,17,17,17,17,17,14],   // O
  [30,17,17,30,16,16,16],   // P
  [14,17,17,17,21,18,13],   // Q
  [30,17,17,30,20,18,17],   // R
  [15,16,16,14,1,1,30],     // S
  [31,4,4,4,4,4,4],         // T
  [17,17,17,17,17,17,14],   // U
  [17,17,17,17,17,10,4],    // V
  [17,17,17,21,21,27,17],   // W
  [17,10,4,4,4,10,17],      // X
  [17,17,10,4,4,4,4],       // Y
  [31,1,2,4,8,16,31],       // Z
  [14,17,19,21,25,17,14],   // 0
  [4,12,4,4,4,4,14],        // 1
  [14,17,1,2,4,8,31],       // 2
  [30,1,1,14,1,1,30],       // 3
  [2,6,10,18,31,2,2],       // 4
  [31,16,30,1,1,17,14],     // 5
  [14,16,16,30,17,17,14],   // 6
  [31,1,2,4,4,4,4],         // 7
  [14,17,17,14,17,17,14],   // 8
  [14,17,17,15,1,1,14],     // 9
  [0,0,0,0,0,12,12],        // .
  [4,4,4,4,4,0,4],          // !
  [14,17,1,2,4,0,4],        // ?
  [0,0,0,31,0,0,0],         // -
  [0,4,4,0,4,4,0],          // :
  [4,4,8,0,0,0,0]           // '
];

// Rows for one character: lowercase folds to uppercase; any
// character outside CHARSET maps to '?'. Returns a copy.
function glyphRows(ch) {
  var s = String(ch == null ? '' : ch), c = s.length ? s[0] : '?';
  if (c >= 'a' && c <= 'z') c = c.toUpperCase();
  var i = CHARSET.indexOf(c);
  if (i < 0) i = CHARSET.indexOf('?');
  return GLYPHS[i].slice();
}

// Flat triangle vertices [x,y,z, ...] for `text`, in the XY plane
// facing +Z, starting at `origin` (the glyph block's bottom-left;
// row 0 is the TOP row, so a glyph spans origin.y .. origin.y+size).
// Pixel height ph = size/7, square pixels pw = ph, glyph width
// 5*pw, advance 6*pw. Two triangles (CCW from +Z) per ON pixel.
function textTriangles(text, origin, size) {
  var o = v3(origin, [0, 0, 0]), s = String(text == null ? '' : text),
      ph = (size || 0) / 7, pw = ph, out = [], i, r, c;
  for (i = 0; i < s.length; i++) {
    var rows = glyphRows(s[i]), gx = o[0] + i * 6 * pw;
    for (r = 0; r < 7; r++) {
      var y0 = o[1] + (6 - r) * ph, y1 = y0 + ph;
      for (c = 0; c < 5; c++) {
        if (!((rows[r] >> (4 - c)) & 1)) continue;
        var x0 = gx + c * pw, x1 = x0 + pw, z = o[2];
        out.push(x0, y0, z, x1, y0, z, x1, y1, z,
                 x0, y0, z, x1, y1, z, x0, y1, z);
      }
    }
  }
  return out;
}

// Total advance width: len*6*(size/7) - size/7 (no trailing gap),
// 0 for empty text.
function textWidth(text, size) {
  var n = String(text == null ? '' : text).length;
  return n === 0 ? 0 : n * 6 * ((size || 0) / 7) - (size || 0) / 7;
}

export { spriteBasis, spriteQuad, glyphRows, textTriangles,
  textWidth, CHARSET, GLYPHS };

// Compatibility footer: attach the exported names onto
// globalThis.F3D (and keep the legacy F3DSpritesText global) for
// classic-bundle / non-module consumers.
globalThis.F3D = globalThis.F3D || {};
globalThis.F3D.F3DSpritesText = { spriteBasis: spriteBasis,
  spriteQuad: spriteQuad, glyphRows: glyphRows,
  textTriangles: textTriangles, textWidth: textWidth,
  CHARSET: CHARSET, GLYPHS: GLYPHS };
globalThis.F3D.spriteBasis = spriteBasis;
globalThis.F3D.spriteQuad = spriteQuad;
globalThis.F3D.glyphRows = glyphRows;
globalThis.F3D.textTriangles = textTriangles;
globalThis.F3D.textWidth = textWidth;
globalThis.F3D.CHARSET = CHARSET;
globalThis.F3D.GLYPHS = GLYPHS;
globalThis.F3DSpritesText = globalThis.F3D.F3DSpritesText;
if (typeof window !== 'undefined') window.F3DSpritesText = globalThis.F3DSpritesText;
