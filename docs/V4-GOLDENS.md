# Forge3D v4 Golden Registry — Animation Film

The animation film renderer's golden record, companion to
docs/V3-GOLDENS.md (the v3 still-scene registry).  Where V3 pins
single still frames of compiled `.scene` files, this registry
pins a whole *film*: `examples/anim-golden.f3d`, a two-scene,
48-frame Timeline IR production rendered by the engine's film
mode (`bin/engine3d <file>.timeline.json`).  It is a *record*,
not a CI pin file: CI gates G3d/G3e report the film's hashes on
every run, and a human converts a reviewed hash into this
table.

## The golden film

`examples/anim-golden.f3d` — "Anim Golden", 320×240, 24 fps,
48 frames (2 s), two scenes:

- **Scene 1 "stage" (frames 1–28):** white background, ground
  plane, a red bench cube; character **ada** (blue, tall, round
  head, red cap) walks to the named place `bench-front`
  (18 frames) while the camera pans to the bench (a camera
  track spans frames 0–18), then waves (10 frames).
- **Scene 2 "leap" (frames 29–48):** opens with
  `transition dissolve` of 8 frames; ada jumps (12 frames) then
  smiles (8 frames); a second character, **mira** (pink, kid,
  hair bun), stands at her mark and waves throughout the scene,
  so scene-2 frames are two-figure frames.

The compiled timeline (`build/anim-golden.timeline.json`) has
`duration_frames` 48, spans of 28 + 20 frames, span 2 carrying
`transition {kind: dissolve, duration_frames: 8}`, every
character action track resolved to keys by the stickman plugin
(walk / wave / jump / smile — no core verbs are used on
characters), and a camera track in scene 1.  The single render
line names `output_render.ppm`, so film frame 1 lands in
`output_render.ppm` and every frame also lands in
`output_render_NNNN.ppm` (NNNN = 0001…0048).

## How anim goldens are judged

One criterion, stricter than the v3 stills rule:

1. **Determinism — hard gate, judged by sha256.**  The film
   renderer must produce byte-identical frames for the same
   timeline regardless of thread count.  CI gate G3d renders
   the film under `FORGE3D_THREADS=1` and `FORGE3D_THREADS=8`
   and fails unless the two renders agree on every pinned
   frame; gate G3e does the same for the whole-sequence digest
   (below).  The sha256 values recorded below are the
   deterministic values: any future run, at any thread count,
   must reproduce them exactly until a row is deliberately
   re-pinned.
2. **No PSNR column.**  The v3 registry judges quality against
   the legacy renderer by PSNR, but that comparison does not
   exist here: characters have no legacy path.  The legacy
   renderer never implemented the stickman figure pipeline,
   the action-track resolver, camera tracks, or transition
   blending, so there is no legacy render of this film to
   measure against — a PSNR figure would be a comparison
   against a renderer that cannot produce the content at all.
   Quality is therefore guarded by the pin itself plus the
   re-pin review (a reviewer must eyeball the pinned frames
   and say why the pixels moved), not by a numeric distance
   to legacy.

## Registry

Measured 2026-11-26 on the Wave 3 tree (v3 film renderer,
`FORGE3D_THREADS=1`; every frame verified byte-identical at
`FORGE3D_THREADS=8`).  Frame numbers are the rendered file
suffixes (`output_render_NNNN.ppm`, 1-based); timeline frame
indices are 0-based, so file NNNN is timeline frame NNNN−1.
The sequence digest is the sha256 of the concatenation of all
48 numbered frame files in order
(`cat output_render_*.ppm | sha256sum`).

| frame | what it pins | renderer | sha256 | threads | date |
|---|---|---|---|---|---|
| 0001 | frame 1 (t=0; also written to `output_render.ppm`): ada at her start mark, bench staged right | v3 film | `0de3d3650368c3926b2c264af023342dc18aae350977310dd679e0fe615d56cd` | 1 (= 8) | 2026-11-26 |
| 0010 | mid-walk (timeline frame 9): ada mid-stride toward bench-front, camera pan under way | v3 film | `5223a8e723146acc24b80c193231f072c661c92188b3c25a529a3752e1ace899` | 1 (= 8) | 2026-11-26 |
| 0024 | wave (timeline frame 23): ada at bench-front, arm raised mid-wave | v3 film | `775aa3e06f6acb0602c51e2ce8cd6ba81768e306470e83f5aab076215e82b9e7` | 1 (= 8) | 2026-11-26 |
| 0032 | transition midpoint (span-2 local frame 3): dissolve blend of stage and leap, both figures present | v3 film | `08d5ae5fc545c0acde800210251793d7e86b83d990d57fc8a595dccceab8fc8d` | 1 (= 8) | 2026-11-26 |
| 0035 | jump apex (timeline frame 34, the jump track's peak root.y key): ada airborne, mira waving beside her | v3 film | `e2ca353431251d908d82ab802b9b850db16f9aa85ed84c179adadea039e37f33` | 1 (= 8) | 2026-11-26 |
| 0048 | final frame: ada smiling after the leap, mira waving — the two-figure closing frame | v3 film | `e532266317f632c9d7c01c2daa4672ea89c488afb995a08ef651c99fa3e4b8cb` | 1 (= 8) | 2026-11-26 |
| all 48 | sequence digest (`cat output_render_*.ppm \| sha256sum`) | v3 film | `dd61c362ffdb1199156e37edd98684aefd6a2b29cb4046e511ceb3adb8562c44` | 1 (= 8) | 2026-11-26 |

## Provenance

First pin, recorded 2026-11-26 by the Wave 3 anim-golden slice
that authored the film, its CI gates, and this registry in one
change.  The hashes were measured on the integrated Wave 3
tree (engine film mode landed: timeline spans, resolved action
tracks, camera tracks, dissolve blending) by building
`examples/anim-golden.f3d` with `bin/f3dc`, rendering
`build/anim-golden.timeline.json` with `bin/engine3d` in two
isolated directories at `FORGE3D_THREADS=1` and
`FORGE3D_THREADS=8`, and confirming all 49 emitted PPMs (frame
1's base file plus the 48 numbered frames) byte-identical
across the two runs before hashing.  Every pinned frame was
sanity-checked before pinning — `tests/golden/check_image.f90`
reports each one non-flat at 320×240 (distinct colours 5–19),
and a colour census confirms the figures are in frame: ada's
blue reads (133, 168, 248) and mira's pink (248, 202, 224)
after the v3 output transform, the bench's red shades are
staged in scene 1, frame 0032 shows the dissolve ghost of the
bench alongside both figures, and frame 0035 shows ada raised
at the jump track's peak root.y key (timeline frame 34).

## Re-pin history

**Wave 3 figure fix (2026-11-26, same wave, before first CI)** --
all seven values re-pinned.  Cause: the stickman figure's
single-sided flat parts (cap fan/brim, eyes, hair bun, glasses)
were wound to face away in the renderers' y-down screen-space
culling and were silently culled; `src/char_figure.f90` now
emits the screen-facing winding, adds shoulder/hip bars, raises
the cap dome above the eye line, and enlarges the eyes.  Only
character pixels moved; the pre-fix pins are the ones recorded
in the Provenance paragraph's first-pin measurement.

*(Empty.  No re-pin has happened yet; the first re-pin adds
its entry here, newest first, in the V3-GOLDENS.md style:
what moved, the cause, and the old → new hashes.)*

## Re-pinning procedure

Same rule as the legacy blessing and the v3 registry: a
golden moves only by a deliberate, human-reviewed change —
never as a side effect of a code change, and never to make a
red run green after the fact.

1. Reproduce the change: build the film, render its timeline
   with the v3 film renderer at `FORGE3D_THREADS=1` and
   `FORGE3D_THREADS=8`; confirm the two frame sets agree
   byte-for-byte (determinism first — a non-deterministic
   render is a bug, not a new golden).
2. Eyeball every pinned frame that moved and be able to say
   *why* the pixels moved (the intended change that caused
   it).  There is no PSNR shortcut here (see "How anim
   goldens are judged"): if a figure is missing, misplaced,
   or a frame is blank, the fix belongs in the scene or the
   renderer, not in the pin.
3. Update the rows in this file (sha256, date) and the hash
   literals in the CI G3d/G3e steps in the same commit as the
   code change that caused it, and name that cause in the
   commit message.
4. Check CI: the next G3d/G3e runs' `$GITHUB_STEP_SUMMARY`
   lines must match the new rows.
