'use strict';
/* host_sim.js -- the HOST-SIMULATION consumer for Forge3D Timeline
 * IR v1 (Animation Compiler Wave 2, slice B2; tests/ir/).
 *
 * This is the artefact StykAnimate reuses: a small standalone
 * consumer that reads ONLY a .timeline.json file and extracts the
 * performance data a host needs -- characters, per-scene spans,
 * tracks with keys, dialogue cues, markers. It was written from
 * docs/TIMELINE-FORMAT.md alone: no compiler internals, no schema
 * file at runtime (the reader obligations are coded directly from
 * the spec). Zero dependencies.
 *
 *     node tests/ir/host_sim.js <file.timeline.json>
 *         prints the extraction as JSON on stdout; diagnostics
 *         (skipped unknown track kinds, unmapped spans, unknown
 *         eases) go to stderr; exit 1 with a named error when the
 *         file is rejected.
 *
 *     const { extractTimeline } = require('./host_sim');
 *         extractTimeline(rawText) -> { data, diagnostics }
 *         throws Error on rejection.
 *
 * Reader obligations implemented (TIMELINE-FORMAT.md, "Reader
 * obligations"):
 *   1. format checked first: must equal "forge3d-timeline";
 *      missing format is a rejection, not a default.
 *   2. ir_version gated exactly: only 1 is implemented; any other
 *      version is rejected NAMING the version found; missing
 *      ir_version is a rejection, not a default.
 *   3. Unknown keys ignored at every level.
 *   4. Unknown track kinds skipped WITH a diagnostic (stderr +
 *      result.diagnostics), never a crash, never a silent drop.
 *   5. Unknown/malformed ease -> the segment is kept, the ease is
 *      reported in diagnostics (a host evaluating it must fall
 *      back to linear; extraction itself does not evaluate).
 *   6. Unresolvable data is reported, never approximated: action
 *      tracks with "resolved": false land in result.unmapped.
 *   7. Frames are canonical: all timing below is integer frames
 *      under the in-file fps rational; t_seconds, if present, is
 *      never read.
 */

const KNOWN_TRACK_KINDS = new Set(['action', 'pose_keys', 'verb', 'camera', 'visibility']);
const KNOWN_EASES = new Set(['linear', 'smooth', 'in', 'out',
  'cubic-in', 'cubic-out', 'cubic-in-out', 'hold']);
const BEZIER_RE = /^bezier\((-?\d+(\.\d+)?),(-?\d+(\.\d+)?),(-?\d+(\.\d+)?),(-?\d+(\.\d+)?)\)$/;

function reject(msg) { throw new Error('host_sim: ' + msg); }

function extractTimeline(raw) {
  let doc;
  try { doc = JSON.parse(raw); } catch (e) {
    reject('file is not valid JSON (' + e.message + ')');
  }
  if (doc === null || typeof doc !== 'object' || Array.isArray(doc)) {
    reject('top level is not a JSON object');
  }
  /* Obligation 1: the discriminator, first. */
  if (!('format' in doc)) reject('missing "format" (a timeline file must carry "format": "forge3d-timeline")');
  if (doc.format !== 'forge3d-timeline') {
    reject('wrong "format" ' + JSON.stringify(doc.format) + ' (expected "forge3d-timeline")');
  }
  /* Obligation 2: exact version gate, naming the version found. */
  if (!('ir_version' in doc)) reject('missing "ir_version" (no default version is assumed)');
  if (doc.ir_version !== 1) {
    reject('unsupported ir_version ' + JSON.stringify(doc.ir_version) +
           ' (this reader implements ir_version 1 only)');
  }

  const diagnostics = [];
  const unmapped = [];

  const characters = (doc.characters || []).map((c) => ({
    id: c.id, name: c.name, plugin: c.plugin, color: c.color,
    rig: c.rig,
    ...(c.proportions !== undefined ? { proportions: c.proportions } : {}),
    ...(c.voice !== undefined ? { voice: c.voice } : {}),
  }));

  const scenes = (doc.scenes || []).map((s) => ({
    id: s.id, name: s.name, scene_file: s.scene_file,
    scene_ir_version: s.scene_ir_version,
    start_frame: s.start_frame,
    end_frame: s.start_frame + s.duration_frames,
    duration_frames: s.duration_frames,
    bindings: s.bindings || {},
  }));

  function checkEase(ease, where) {
    if (typeof ease === 'string' && !KNOWN_EASES.has(ease) && !BEZIER_RE.test(ease)) {
      diagnostics.push('unknown ease "' + ease + '" at ' + where +
                       ' (reader falls back to linear for that segment)');
    }
  }

  const tracks = [];
  (doc.tracks || []).forEach((t, i) => {
    const where = 'tracks[' + i + ']';
    /* Obligation 4: unknown kinds skipped with a diagnostic. */
    if (!KNOWN_TRACK_KINDS.has(t.kind)) {
      diagnostics.push('skipped unknown track kind ' + JSON.stringify(t.kind) +
                       ' at ' + where + ' (scene ' + JSON.stringify(t.scene) + ')');
      return;
    }
    const base = { kind: t.kind, scene: t.scene };
    if (t.kind === 'action') {
      const rec = { ...base, character: t.character, action: t.action,
        start_frame: t.start_frame, end_frame: t.end_frame,
        resolved: t.resolved !== false };
      if (t.params !== undefined) rec.params = t.params;
      if (t.resolved === false) {
        /* Obligation 6: report, never approximate. */
        unmapped.push({ kind: 'action', character: t.character, action: t.action,
          scene: t.scene, start_frame: t.start_frame, end_frame: t.end_frame,
          reason: 'resolved: false (no keys in the IR)' });
      } else {
        rec.keys = (t.keys || []).map((k) => ({ ...k }));
        rec.keys.forEach((k, j) => checkEase(k.ease, where + '.keys[' + j + ']'));
      }
      tracks.push(rec);
    } else if (t.kind === 'pose_keys' || t.kind === 'camera') {
      const rec = { ...base };
      if (t.character !== undefined) rec.character = t.character;
      if (t.target !== undefined) rec.target = t.target;
      rec.keys = (t.keys || []).map((k) => ({ ...k }));
      rec.keys.forEach((k, j) => checkEase(k.ease, where + '.keys[' + j + ']'));
      tracks.push(rec);
    } else if (t.kind === 'verb') {
      tracks.push({ ...base, target: t.target, verb: t.verb,
        start_frame: t.start_frame, end_frame: t.end_frame,
        ...(t.params !== undefined ? { params: t.params } : {}) });
    } else if (t.kind === 'visibility') {
      const rec = { ...base, start_frame: t.start_frame,
        end_frame: t.end_frame, visible: t.visible };
      if (t.character !== undefined) rec.character = t.character;
      if (t.target !== undefined) rec.target = t.target;
      tracks.push(rec);
    }
  });

  const dialogue = (doc.dialogue || []).map((d) => ({
    id: d.id, scene: d.scene, speaker: d.speaker,
    start_frame: d.start_frame, end_frame: d.end_frame, text: d.text,
  }));

  const markers = (doc.markers || []).map((m) => ({
    frame: m.frame, name: m.name, kind: m.kind,
  }));

  return {
    data: {
      name: doc.name,
      fps: doc.fps,
      duration_frames: doc.duration_frames,
      characters, scenes, tracks, dialogue, markers,
    },
    diagnostics,
    unmapped,
  };
}

if (require.main === module) {
  const fs = require('fs');
  const file = process.argv[2];
  if (!file) {
    console.error('usage: node host_sim.js <file.timeline.json>');
    process.exit(2);
  }
  let result;
  try {
    result = extractTimeline(fs.readFileSync(file, 'utf8'));
  } catch (e) {
    console.error(e.message);
    process.exit(1);
  }
  for (const d of result.diagnostics) console.error('diagnostic: ' + d);
  for (const u of result.unmapped) {
    console.error('unmapped: ' + u.action + ' by ' + u.character +
                  ' [' + u.start_frame + ', ' + u.end_frame + ') -- ' + u.reason);
  }
  console.log(JSON.stringify(result.data, null, 2));
}

module.exports = { extractTimeline };
