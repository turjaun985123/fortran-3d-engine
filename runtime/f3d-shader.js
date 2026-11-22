// Forge3D custom shaders sidecar - OPTIONAL module, load AFTER
// runtime/f3d.js (or standalone: it has no dependencies).
// GLSL-free: this is the CPU mirror of src/shader.f90. It takes
// the identical RPN token stream the Fortran compiler emits and
// produces identical results -- there is no GLSL anywhere in the
// pipeline; the same expression can be evaluated on the CPU here
// or in Fortran and must agree. Plain script, zero deps, no
// modules; registers window.Forge3DShader.
//
// RPN tokens: numbers (as numbers or numeric strings); the
// variables c r g b x y z u v ndl t (c = current channel value,
// r/g/b = base colour, x/y/z = position, u/v = texcoords,
// ndl = N.L lighting term, t = time); the constant pi; the
// binary operators + - * / % ^; the unary operator neg; and the
// functions sin cos tan abs sqrt floor ceil fract (1 arg),
// min max step pow (2 args), clamp mix (3 args).
// Semantics guards, exactly as the Fortran/compiler contract:
//   division by zero -> 0;  modulo by zero -> 0;
//   pow with an invalid domain (negative base with a
//   non-integer exponent, or 0 to a negative power) -> 0,
//   while 0^0 = 1;  sqrt of a negative -> 0.
// Note on %: Fortran MOD(a, b) takes the sign of a (the
// dividend), and JavaScript's % does the same (sign of the
// dividend) -- so a % b here matches Fortran MOD directly.
// (Python's %, by contrast, takes the sign of the divisor.)
'use strict';
(function (g) {
var VARS = { c: 1, r: 1, g: 1, b: 1, x: 1, y: 1, z: 1,
             u: 1, v: 1, ndl: 1, t: 1 };
var OPS = { '+': 1, '-': 1, '*': 1, '/': 1, '%': 1, '^': 1 };
var FUN1 = { sin: 1, cos: 1, tan: 1, abs: 1, sqrt: 1,
             floor: 1, ceil: 1, fract: 1 };
var FUN2 = { min: 1, max: 1, step: 1, pow: 1 };
var FUN3 = { clamp: 1, mix: 1 };

function isNumberToken(tok) {
  if (typeof tok === 'number') return isFinite(tok);
  if (typeof tok !== 'string' || tok.trim() === '') return false;
  return isFinite(Number(tok));
}
function arityOf(tok) {
  if (tok === 'neg' || FUN1[tok]) return 1;
  if (OPS[tok] || FUN2[tok]) return 2;
  if (FUN3[tok]) return 3;
  return 0; // value token (number / variable / pi)
}

// Validate an RPN token array: every token must be a known
// number, variable, constant, operator or function; the stack
// may never underflow an operator's arity; and exactly one
// value must remain at the end. Returns a copy of the array.
// Throws an Error with a clear message on any violation.
function parseRPN(tokens) {
  if (!Array.isArray(tokens))
    throw new Error('parseRPN: tokens must be an array');
  var depth = 0, i, tok, arity;
  for (i = 0; i < tokens.length; i++) {
    tok = tokens[i];
    if (isNumberToken(tok) || VARS[tok] || tok === 'pi') {
      depth += 1;
      continue;
    }
    arity = (typeof tok === 'string') ? arityOf(tok) : 0;
    if (!arity)
      throw new Error('parseRPN: unknown variable/function/'
        + 'operator token: ' + String(tok));
    if (depth < arity)
      throw new Error('parseRPN: stack underflow at token '
        + i + ' (' + String(tok) + ' needs ' + arity
        + ' operand' + (arity > 1 ? 's' : '') + ', stack has '
        + depth + ')');
    depth = depth - arity + 1;
  }
  if (depth !== 1)
    throw new Error('parseRPN: leftover stack must be exactly '
      + '1 value, got ' + depth + ' (from ' + tokens.length
      + ' token' + (tokens.length === 1 ? '' : 's') + ')');
  return tokens.slice();
}

function safePow(a, b) {
  if (a === 0) return b < 0 ? 0 : Math.pow(a, b); // 0^0 = 1
  if (a < 0 && b !== Math.floor(b)) return 0; // invalid domain
  var v = Math.pow(a, b);
  return (typeof v === 'number' && !isNaN(v)) ? v : 0;
}
function clampVal(x, a, b) { return Math.min(Math.max(x, a), b); }

function applyFun1(name, a) {
  switch (name) {
    case 'sin': return Math.sin(a);
    case 'cos': return Math.cos(a);
    case 'tan': return Math.tan(a);
    case 'abs': return Math.abs(a);
    case 'sqrt': return a < 0 ? 0 : Math.sqrt(a); // guard
    case 'floor': return Math.floor(a);
    case 'ceil': return Math.ceil(a);
    case 'fract': return a - Math.floor(a);
    case 'neg': return -a;
  }
  throw new Error('evalRPN: unknown function: ' + name);
}
function applyBinary(op, a, b) {
  switch (op) {
    case '+': return a + b;
    case '-': return a - b;
    case '*': return a * b;
    case '/': return b === 0 ? 0 : a / b; // guard: div0 -> 0
    case '%': return b === 0 ? 0 : a % b; // guard; sign of a
    case '^': return safePow(a, b);
    case 'min': return Math.min(a, b);
    case 'max': return Math.max(a, b);
    // step(edge, x) = x >= edge ? 1 : 0
    case 'step': return b >= a ? 1 : 0;
    case 'pow': return safePow(a, b);
  }
  throw new Error('evalRPN: unknown operator: ' + op);
}

// Evaluate a (validated) RPN token array against env, whose
// keys are the variable names above; missing keys read as 0.
// Returns a single number.
function evalRPN(rpn, env) {
  var toks = parseRPN(rpn);
  env = env || {};
  var stack = [], i, tok, a, b, c;
  function val(name) {
    var v = env[name];
    return (typeof v === 'number' && isFinite(v)) ? v : 0;
  }
  for (i = 0; i < toks.length; i++) {
    tok = toks[i];
    if (isNumberToken(tok)) { stack.push(Number(tok)); continue; }
    if (tok === 'pi') { stack.push(Math.PI); continue; }
    if (VARS[tok]) { stack.push(val(tok)); continue; }
    if (tok === 'neg' || FUN1[tok]) {
      stack.push(applyFun1(tok, stack.pop()));
    } else if (OPS[tok] || FUN2[tok]) {
      b = stack.pop(); a = stack.pop();
      stack.push(applyBinary(tok, a, b));
    } else { // FUN3: clamp(x, a, b), mix(a, b, f)
      c = stack.pop(); b = stack.pop(); a = stack.pop();
      stack.push(tok === 'clamp'
        ? clampVal(a, b, c) : a + (b - a) * c);
    }
  }
  return stack[0];
}

// Shade one channel: evaluate, clamp to [0, 1], scale to a
// byte. Math.round is half-up; Fortran nint is half-to-even --
// they agree on the 0.5 case that matters here:
// 0.5 * 255 = 127.5 -> 128 in both.
function shadeChannel(rpn, env) {
  return Math.round(clampVal(evalRPN(rpn, env), 0, 1) * 255);
}

// Shade one pixel: evaluate the RPN once per channel, with c
// set to that channel of baseRGB and r/g/b set from the whole
// baseRGB (all normalised to [0, 1] from byte values), on top
// of envBase (position, uv, ndl, t, ...). Returns [r, g, b]
// byte integers -- this is what a renderer calls per pixel.
function shadeRGB(rpn, baseRGB, envBase) {
  var base = [baseRGB[0] / 255, baseRGB[1] / 255,
              baseRGB[2] / 255];
  var out = [], ch, env;
  for (ch = 0; ch < 3; ch++) {
    env = Object.assign({}, envBase || {},
      { c: base[ch], r: base[0], g: base[1], b: base[2] });
    out.push(shadeChannel(rpn, env));
  }
  return out;
}

g.Forge3DShader = { parseRPN: parseRPN, evalRPN: evalRPN,
  shadeChannel: shadeChannel, shadeRGB: shadeRGB };
if (typeof window !== 'undefined')
  window.Forge3DShader = g.Forge3DShader;
})(typeof globalThis !== 'undefined' ? globalThis : this);
