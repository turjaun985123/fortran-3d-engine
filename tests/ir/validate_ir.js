'use strict';
/* validate_ir.js -- standalone Timeline IR v1 validator
 * (Forge3D Animation Compiler Wave 2, slice B2; tests/ir/).
 *
 *     node tests/ir/validate_ir.js <file.timeline.json> [...]
 *
 * Exit 0 when every file conforms, 1 otherwise; every failure is
 * printed as a NAMED failure line ("FAIL <check-name>: <detail>").
 * The rules come from docs/TIMELINE-FORMAT.md (the spec, ADR-5) as
 * distilled into the purpose schema timeline_schema.json beside
 * this file (required keys, types, enum sets). The cross-field
 * rules a per-record schema cannot express are implemented here:
 *
 *   - alphabetical key order at every object level
 *   - tracks sorted by (scene, kind, character/target, start_frame)
 *   - keys within a track sorted by frame (equal-frame rules per
 *     spec: same frame+channel for action tracks, same frame else)
 *   - scene spans partition [0, duration_frames) without overlap
 *   - fps {num, den} positive ints, gcd-reduced
 *   - raw-byte float hygiene: no "-0" tokens, no whole-valued
 *     floats written with a decimal point ("60.0"), no BOM
 *   - integer frames everywhere; dialogue end > start and
 *     end >= start on every other span; dialogue text non-empty
 *   - referential integrity: track/dialogue scene ids, speaker and
 *     track character ids, scene bindings keys all resolve
 *
 * Unknown keys at any level are TOLERATED (the spec's forward-
 * compatibility rule), never a failure. Unknown marker kinds are
 * likewise tolerated (safely-skippable enum values); unknown track
 * kinds and unknown ease spellings ARE failures -- the v1 emitter
 * writes only the closed sets in the schema.
 *
 * Also usable as a module: require('./validate_ir').validateText
 * (rawText) -> array of named failure strings (empty = conforming).
 * Zero dependencies; no Python anywhere in this layer.
 */
const fs = require('fs');
const path = require('path');

const SCHEMA = JSON.parse(fs.readFileSync(
  path.join(__dirname, 'timeline_schema.json'), 'utf8'));

const BEZIER_RE = new RegExp(SCHEMA.enums.ease.bezier_pattern);
const EASE_NAMES = new Set(SCHEMA.enums.ease.names);
const TRACK_KINDS = new Set(SCHEMA.enums.track_kinds);
const SLUG_RE = /^[a-z0-9]+(-[a-z0-9]+)*$/;

const isInt = (v) => typeof v === 'number' && Number.isInteger(v);
const isNum = (v) => typeof v === 'number' && Number.isFinite(v);

function gcd(a, b) { return b === 0 ? a : gcd(b, a % b); }

function typeOk(v, t) {
  switch (t) {
    case 'string': return typeof v === 'string';
    case 'int': return isInt(v);
    case 'number': return isNum(v);
    case 'bool': return typeof v === 'boolean';
    case 'array': return Array.isArray(v);
    case 'object': return v !== null && typeof v === 'object' && !Array.isArray(v);
    case 'vec3': return Array.isArray(v) && v.length === 3 && v.every(isNum);
    case 'color3': return Array.isArray(v) && v.length === 3 &&
      v.every((c) => isInt(c) && c >= 0 && c <= 255);
    case 'slug': return typeof v === 'string' && SLUG_RE.test(v);
    case 'number-or-vec3': return isNum(v) ||
      (Array.isArray(v) && v.length === 3 && v.every(isNum));
    default: return true;
  }
}

/* Scan raw JSON text for number tokens outside string literals and
 * flag the two float-formatting violations the spec forbids:
 * negative zero in any notation, and a whole-valued number written
 * with a decimal point (the emitter writes those as integers). */
function rawByteFailures(raw) {
  const out = [];
  if (raw.charCodeAt(0) === 0xFEFF) out.push('bom: file starts with a UTF-8 BOM');
  let i = 0;
  const n = raw.length;
  while (i < n) {
    const ch = raw[i];
    if (ch === '"') {
      i++;
      while (i < n && raw[i] !== '"') { if (raw[i] === '\\') i++; i++; }
      i++;
      continue;
    }
    if (ch === '-' || (ch >= '0' && ch <= '9')) {
      const m = /^-?\d+(\.\d+)?([eE][+-]?\d+)?/.exec(raw.slice(i, i + 40));
      if (m) {
        const tok = m[0];
        if (/^-0(\.0*)?([eE][+-]?\d+)?$/.test(tok) || tok === '-0') {
          out.push('negative-zero: number token "' + tok + '" at byte ' + i);
        } else if (tok.indexOf('.') !== -1 && !/[eE]/.test(tok) &&
                   Number.isInteger(Number(tok))) {
          out.push('whole-float: whole-valued float "' + tok +
                   '" written with a decimal point at byte ' + i);
        }
        i += tok.length;
        continue;
      }
    }
    i++;
  }
  return out;
}

/* Alphabetical key order at every object level (emitter guarantee
 * 1). Parsed JS objects preserve insertion order for the string
 * keys this format uses. */
function keyOrderFailures(v, where, out) {
  if (Array.isArray(v)) {
    v.forEach((el, idx) => keyOrderFailures(el, where + '[' + idx + ']', out));
  } else if (v !== null && typeof v === 'object') {
    const keys = Object.keys(v);
    const sorted = [...keys].sort();
    for (let k = 0; k < keys.length; k++) {
      if (keys[k] !== sorted[k]) {
        out.push('key-order: object at ' + where + ' has key "' + keys[k] +
                 '" out of alphabetical order (keys: ' + keys.join(',') + ')');
        break;
      }
    }
    for (const k of keys) keyOrderFailures(v[k], where + '.' + k, out);
  }
  return out;
}

function checkRecord(rec, spec, where, out) {
  if (rec === null || typeof rec !== 'object' || Array.isArray(rec)) {
    out.push('record-type: ' + where + ' is not an object');
    return;
  }
  for (const req of spec.required || []) {
    if (!(req in rec)) out.push('missing-field: ' + where + ' lacks required "' + req + '"');
  }
  for (const [key, t] of Object.entries(spec.properties || {})) {
    if (key in rec && !typeOk(rec[key], t)) {
      out.push('field-type: ' + where + '.' + key + ' should be ' + t +
               ', got ' + JSON.stringify(rec[key]));
    }
  }
}

function checkEase(ease, where, out) {
  if (typeof ease !== 'string') {
    out.push('field-type: ' + where + ' ease should be a string');
    return;
  }
  if (!EASE_NAMES.has(ease) && !BEZIER_RE.test(ease)) {
    out.push('ease-spelling: ' + where + ' has non-canonical ease "' + ease + '"');
  }
}

function validateText(raw) {
  const out = [];
  out.push(...rawByteFailures(raw));
  let doc;
  try { doc = JSON.parse(raw); } catch (e) {
    out.push('json-parse: ' + e.message);
    return out;
  }
  if (doc === null || typeof doc !== 'object' || Array.isArray(doc)) {
    out.push('record-type: top level is not a JSON object');
    return out;
  }
  keyOrderFailures(doc, '$', out);

  /* Top level */
  checkRecord(doc, SCHEMA.top_level, '$', out);
  if ('format' in doc && doc.format !== SCHEMA.format) {
    out.push('format-value: "format" is ' + JSON.stringify(doc.format) +
             ', expected "' + SCHEMA.format + '"');
  }
  if ('ir_version' in doc && doc.ir_version !== SCHEMA.ir_version) {
    out.push('ir-version: "ir_version" is ' + JSON.stringify(doc.ir_version) +
             ', this schema covers ' + SCHEMA.ir_version);
  }
  if (!isInt(doc.duration_frames) || doc.duration_frames < 0) {
    out.push('field-type: $.duration_frames should be a non-negative int');
  }

  /* fps */
  if (doc.fps && typeof doc.fps === 'object') {
    checkRecord(doc.fps, SCHEMA.fps, '$.fps', out);
    const { num, den } = doc.fps;
    if (isInt(num) && isInt(den)) {
      if (num <= 0 || den <= 0) out.push('fps-positive: fps num/den must be positive ints');
      else if (gcd(num, den) !== 1) {
        out.push('fps-reduced: fps ' + num + '/' + den + ' is not gcd-reduced');
      }
    }
  }

  /* generator */
  if (doc.generator && typeof doc.generator === 'object') {
    checkRecord(doc.generator, SCHEMA.generator, '$.generator', out);
  }

  const characters = Array.isArray(doc.characters) ? doc.characters : [];
  const scenes = Array.isArray(doc.scenes) ? doc.scenes : [];
  const tracks = Array.isArray(doc.tracks) ? doc.tracks : [];
  const dialogue = Array.isArray(doc.dialogue) ? doc.dialogue : [];
  const markers = Array.isArray(doc.markers) ? doc.markers : [];

  /* Characters */
  const charIds = new Set();
  characters.forEach((c, i) => {
    const w = '$.characters[' + i + ']';
    checkRecord(c, SCHEMA.records.Character, w, out);
    if (c && typeof c.id === 'string') {
      if (charIds.has(c.id)) out.push('unique-id: duplicate character id "' + c.id + '"');
      charIds.add(c.id);
    }
    if (c && c.voice && typeof c.voice === 'object') {
      for (const req of SCHEMA.records.Character.voice_required) {
        if (!(req in c.voice)) out.push('missing-field: ' + w + '.voice lacks "' + req + '"');
        else if (typeof c.voice[req] !== 'string') {
          out.push('field-type: ' + w + '.voice.' + req + ' should be a string');
        }
      }
    }
  });

  /* Scenes + partition */
  const sceneIds = new Set();
  if (scenes.length === 0) out.push('scenes-empty: a timeline needs at least one scene span');
  let expectStart = 0;
  scenes.forEach((s, i) => {
    const w = '$.scenes[' + i + ']';
    checkRecord(s, SCHEMA.records.SceneSpan, w, out);
    if (!s || typeof s !== 'object') return;
    if (typeof s.id === 'string') {
      if (sceneIds.has(s.id)) out.push('unique-id: duplicate scene id "' + s.id + '"');
      sceneIds.add(s.id);
    }
    if (isInt(s.duration_frames) && s.duration_frames < 0) {
      out.push('span-positive: ' + w + ' duration_frames must be >= 0');
    }
    if (isInt(s.start_frame) && isInt(s.duration_frames)) {
      if (s.start_frame !== expectStart) {
        out.push('scene-partition: ' + w + ' starts at ' + s.start_frame +
                 ', expected ' + expectStart + ' (spans must be contiguous, ' +
                 'non-overlapping, first span at 0)');
      }
      expectStart = s.start_frame + s.duration_frames;
    }
    if (s.bindings && typeof s.bindings === 'object') {
      for (const cid of Object.keys(s.bindings)) {
        if (!charIds.has(cid)) {
          out.push('ref-integrity: ' + w + '.bindings names unknown character "' + cid + '"');
        }
        if (typeof s.bindings[cid] !== 'string') {
          out.push('field-type: ' + w + '.bindings.' + cid + ' should be a string');
        }
      }
    }
  });
  if (scenes.length && isInt(doc.duration_frames) && expectStart !== doc.duration_frames) {
    out.push('scene-partition: scene spans sum to ' + expectStart +
             ' frames but duration_frames is ' + doc.duration_frames);
  }

  /* Tracks */
  const trackKey = (t) => {
    const who = typeof t.character === 'string' ? t.character :
      (typeof t.target === 'string' ? t.target : '');
    const start = isInt(t.start_frame) ? t.start_frame :
      (Array.isArray(t.keys) && t.keys.length && isInt(t.keys[0].frame)
        ? t.keys[0].frame : 0);
    return [String(t.scene), String(t.kind), who, start];
  };
  tracks.forEach((t, i) => {
    const w = '$.tracks[' + i + ']';
    if (!t || typeof t !== 'object' || Array.isArray(t)) {
      out.push('record-type: ' + w + ' is not an object'); return;
    }
    for (const req of SCHEMA.track.common_required) {
      if (!(req in t)) out.push('missing-field: ' + w + ' lacks required "' + req + '"');
    }
    if (typeof t.scene === 'string' && !sceneIds.has(t.scene)) {
      out.push('ref-integrity: ' + w + ' names unknown scene "' + t.scene + '"');
    }
    if (typeof t.kind !== 'string' || !TRACK_KINDS.has(t.kind)) {
      out.push('track-kind: ' + w + ' has unknown kind ' + JSON.stringify(t.kind) +
               ' (v1 kinds: ' + SCHEMA.enums.track_kinds.join(', ') + ')');
      return;
    }
    const spec = SCHEMA.track.by_kind[t.kind];
    checkRecord(t, spec, w, out);
    if ((t.kind === 'action' || t.kind === 'verb' || t.kind === 'visibility') &&
        isInt(t.start_frame) && isInt(t.end_frame) && t.end_frame <= t.start_frame) {
      out.push('span-positive: ' + w + ' end_frame must be > start_frame');
    }
    if ('character' in t && typeof t.character === 'string' && !charIds.has(t.character)) {
      out.push('ref-integrity: ' + w + ' names unknown character "' + t.character + '"');
    }
    if (t.kind === 'pose_keys' || t.kind === 'visibility') {
      const hasC = 'character' in t, hasT = 'target' in t;
      if (hasC === hasT) {
        out.push('exactly-one-of: ' + w + ' (' + t.kind +
                 ') must carry exactly one of character / target');
      }
    }
    if (t.kind === 'action') {
      if (t.resolved === false && 'keys' in t) {
        out.push('unresolved-keys: ' + w + ' has "resolved": false but still carries keys');
      }
      if (t.resolved !== false && !('keys' in t)) {
        out.push('missing-field: ' + w + ' is a resolved action track without keys');
      }
    }
    if (Array.isArray(t.keys)) {
      let prevFrame = -Infinity;
      const seenActionKeys = new Set();
      t.keys.forEach((k, j) => {
        const kw = w + '.keys[' + j + ']';
        if (!k || typeof k !== 'object') { out.push('record-type: ' + kw + ' is not an object'); return; }
        for (const req of SCHEMA.track.keyed_key_required) {
          if (!(req in k)) out.push('missing-field: ' + kw + ' lacks required "' + req + '"');
        }
        if ('frame' in k && !isInt(k.frame)) out.push('field-type: ' + kw + '.frame should be an int');
        if ('ease' in k) checkEase(k.ease, kw, out);
        if (isInt(k.frame)) {
          if (k.frame < prevFrame) out.push('keys-sorted: ' + kw + ' frame ' + k.frame + ' follows ' + prevFrame);
          if (t.kind === 'action') {
            const sig = k.frame + '|' + k.channel;
            if (seenActionKeys.has(sig)) {
              out.push('keys-equal-frame: ' + kw + ' duplicates (frame, channel) ' + sig);
            }
            seenActionKeys.add(sig);
          } else if (k.frame === prevFrame) {
            out.push('keys-equal-frame: ' + kw + ' duplicates frame ' + k.frame + ' in one track');
          }
          prevFrame = k.frame;
        }
        if (t.kind === 'action') {
          for (const req of spec.key_required) {
            if (!(req in k)) out.push('missing-field: ' + kw + ' lacks required "' + req + '"');
          }
          if (!('value' in k) && !('value_deg' in k)) {
            out.push('missing-field: ' + kw + ' carries neither value nor value_deg');
          }
          if ('value' in k && !isNum(k.value)) out.push('field-type: ' + kw + '.value should be a number');
          if ('value_deg' in k && !isNum(k.value_deg)) out.push('field-type: ' + kw + '.value_deg should be a number');
          if ('channel' in k && typeof k.channel !== 'string') {
            out.push('field-type: ' + kw + '.channel should be a string');
          }
        }
        if (t.kind === 'pose_keys') {
          for (const [f, ty] of Object.entries(spec.key_optional_fields)) {
            if (f in k && !typeOk(k[f], ty)) out.push('field-type: ' + kw + '.' + f + ' should be ' + ty);
          }
        }
        if (t.kind === 'camera') {
          for (const req of spec.key_required) {
            if (!(req in k)) out.push('missing-field: ' + kw + ' lacks required "' + req + '"');
          }
          for (const [f, ty] of Object.entries(spec.key_properties)) {
            if (f in k && !typeOk(k[f], ty)) out.push('field-type: ' + kw + '.' + f + ' should be ' + ty);
          }
        }
      });
    }
    if (i > 0) {
      const a = trackKey(tracks[i - 1]), b = trackKey(t);
      for (let c = 0; c < 4; c++) {
        if (a[c] < b[c]) break;
        if (a[c] > b[c]) {
          out.push('tracks-sorted: ' + w + ' is out of order by ' +
                   '(scene, kind, character/target, start_frame): ' +
                   JSON.stringify(a) + ' precedes ' + JSON.stringify(b));
          break;
        }
      }
    }
  });

  /* Dialogue */
  const dlgIds = new Set();
  let prevDlgStart = -Infinity;
  dialogue.forEach((d, i) => {
    const w = '$.dialogue[' + i + ']';
    checkRecord(d, SCHEMA.records.Dialogue, w, out);
    if (!d || typeof d !== 'object') return;
    if (typeof d.id === 'string') {
      if (dlgIds.has(d.id)) out.push('unique-id: duplicate dialogue id "' + d.id + '"');
      dlgIds.add(d.id);
    }
    if (isInt(d.start_frame) && isInt(d.end_frame) && d.end_frame <= d.start_frame) {
      out.push('span-positive: ' + w + ' end_frame must be > start_frame');
    }
    if (typeof d.text === 'string' && d.text.length === 0) {
      out.push('dialogue-text: ' + w + ' has empty text (the compiler diagnoses instead of emitting)');
    }
    if (typeof d.scene === 'string' && !sceneIds.has(d.scene)) {
      out.push('ref-integrity: ' + w + ' names unknown scene "' + d.scene + '"');
    }
    if (typeof d.speaker === 'string' && !charIds.has(d.speaker)) {
      out.push('ref-integrity: ' + w + ' names unknown speaker "' + d.speaker + '"');
    }
    if (isInt(d.start_frame)) {
      if (d.start_frame < prevDlgStart) out.push('dialogue-sorted: ' + w + ' starts before the previous cue');
      prevDlgStart = d.start_frame;
    }
  });

  /* Markers */
  let prevMarker = -Infinity;
  markers.forEach((m, i) => {
    const w = '$.markers[' + i + ']';
    checkRecord(m, SCHEMA.records.Marker, w, out);
    if (m && isInt(m.frame)) {
      if (m.frame < prevMarker) out.push('markers-sorted: ' + w + ' frame precedes the previous marker');
      prevMarker = m.frame;
    }
  });

  return out;
}

function validateFile(file) {
  return validateText(fs.readFileSync(file, 'utf8'));
}

if (require.main === module) {
  const files = process.argv.slice(2);
  if (!files.length) {
    console.error('usage: node validate_ir.js <file.timeline.json> [...]');
    process.exit(2);
  }
  let bad = 0;
  for (const f of files) {
    let failures;
    try { failures = validateFile(f); } catch (e) {
      console.error('FAIL read: ' + f + ': ' + e.message);
      bad++;
      continue;
    }
    if (failures.length) {
      bad++;
      for (const msg of failures) console.error('FAIL ' + msg + '  [' + f + ']');
    } else {
      console.log('OK ' + f);
    }
  }
  process.exit(bad ? 1 : 0);
}

module.exports = { validateText, validateFile };
