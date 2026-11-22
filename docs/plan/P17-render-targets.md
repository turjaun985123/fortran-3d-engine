# P17 — Render Targets: PPM, PNG, Animation Frames, HTML Viewer, CLI & Naming

> **Status:** Planning only — no `src/` changes in this document.
> **Repo baseline (verified 2026-11-23):** `src/renderer.f90` (`renderer_3d`) exports
> exactly one image format; `src/main.f90` is a hard-coded 640×480 still; PNG exists
> only as an optional side-effect of `make run`; `viewer.html` is a hand-maintained
> checked-in file, not an emitted target.
> **Product goal:** an *easy* 3D compiler — one command in, the file the user actually
> wants out (`viewable PNG`, `shareable HTML`, `frames for a video`), with no manual
> conversion step and no surprise filenames.

---

## 1. Current State (grounded)

| Fact | Where |
|---|---|
| Only writer: `framebuffer_save_ppm(fb, filename)` — ASCII **P3**, maxval `255`, one row per line, `status='replace'`. No P6, no PNG, no dispatch, no error return. | `src/renderer.f90:141-159`, public list `:8` |
| Pixels already in the ideal shape for any writer: `FrameBuffer%pixels(3,width,height)` integer RGB `0..255`, plus `z_buffer(width,height)`. Every target below is a serialisation of this array — no renderer change is needed. | `src/renderer.f90:11-16` |
| Output name/size are literals, not options: `width=640, height=480, output_file='output_render.ppm'`. No `get_command_argument` / `command_argument_count` anywhere in `src/`. | `src/main.f90:14-18` |
| PNG today = external, optional, silent: `make run` runs `which convert && convert output_render.ppm output_render.png \|\| true`. If ImageMagick is absent the build *succeeds* with no PNG and no warning; the checked-in `output_render.png` (1.2 KB) is stale relative to the 3.6 MB `output_render.ppm`. | `Makefile:50`, `README.md:47-52` |
| Animation frames do not exist: one render, one `framebuffer_save_ppm`, exit. Frame-sequence naming `frame_%04d.ppm`, fps/duration and the frame loop are owned by P09 (§8 there already assumes this plan supplies `--fps/--frame` flags and the pattern). | `src/main.f90` (whole), `docs/plan/P09-animation-timeline.md` §8, §10 |
| HTML is not a target: `viewer.html` is checked in, hard-codes a fallback cube, `fetch('scene.json')`, and in its PPM tab `fetch('output_render.ppm')` with a PNG fallback (`output_render.png`) for the `file://` CORS failure. Its decoder claims P3/P6 in prose but `parseAndRenderPPM` rejects anything whose magic is not `P3`. | `viewer.html` (tabs, `loadDefaultPPM`, `parseAndRenderPPM`) |
| Sidecar exports are unconditional literals too: `export_mesh_json(cube,'scene.json')`, `export_mesh_obj(cube,'model.obj')` on every run, overwriting the checked-in files in the CWD. | `src/main.f90:56-58`, `src/mesh.f90` |
| P3 cost is real: 640×480 P3 ≈ 3.6 MB/still (measured). P09 §11: 120 frames ≈ hundreds of MB — P3 alone is not a viable animation target. | `output_render.ppm`, P09 §11 |

**Consequence:** render targets are an *output layer + CLI* problem, not a rasteriser
problem: (1) a format-dispatch writer over the existing `FrameBuffer`, (2) argument
parsing where today there are literals, (3) one naming/precedence rule shared by the
native binary (`bin/engine3d`) and the compiler driver (`f3dc`, P04 §10).

---

## 2. Principles

1. **Default output must be openable by double-click.** PPM is not (browsers reject it —
   `viewer.html`'s own instructions card says so). The beginner default therefore cannot
   stay "PPM only": default target set is `ppm,png,html` for a still (§7), PPM retained
   as the canonical/golden format, PNG as the viewable one, HTML as the interactive one.
2. **No silent degradation.** Today's `|| true` conversion is the anti-pattern: if PNG
   was requested and no converter/native writer can produce it, that is an error with a
   remedy in the message — never a successful run missing a promised file.
3. **One naming rule, everywhere.** Native binary, `f3dc build/run`, Makefile and the
   HTML viewer all resolve names through §7. No target invents its own filename.
4. **Deterministic and diffable.** Same scene + flags → same filenames and, for PPM/P6/
   native-PNG, byte-identical files. No timestamps inside image files; HTML embeds no
   timestamp by default (cf. P04 §1 determinism invariant).
5. **Zero new mandatory dependencies.** Base install stays `gfortran + python3`
   (P04 §8). ImageMagick/ffmpeg are *opportunistic accelerators*, detected and named in
   output when used — never assumed.
6. **Never clobber silently.** Writers use `status='replace'` today; §7.4 adds the
   compiler-level guard: refuse to overwrite a file that is not a previous generated
   output unless `--force`, and never write into the repo root by default.

---

## 3. Target Matrix

| Target | Ext | Producer (planned) | Default? | § |
|---|---|---|---|---|
| PPM P3 (ASCII) | `.ppm` | `framebuffer_save_ppm` — exists, unchanged semantics | Yes (canonical, golden) | §4.1 |
| PPM P6 (binary) | `.ppm` | New `framebuffer_save_ppm_p6` | For animation; opt-in for stills | §4.2 |
| PNG (via conversion) | `.png` | External converter over the just-written PPM | Yes, when a converter exists | §5.1 |
| PNG (native) | `.png` | New pure-Fortran writer (stored-zlib, §5.2) | Yes, once P17-c lands — replaces conversion as default path | §5.2 |
| Animation frames | `frame_%04d.ppm/.png` | Frame loop (P09) + per-frame dispatch | Only in animation mode | §6 |
| HTML viewer | `.html` | Compiler template emit (P04 §6.4) / copied+parameterised `viewer.html` for native runs | Yes for stills, playlist mode for animation | §8 |
| Sidecars (existing) | `scene.json`, `model.obj` | `export_mesh_json/obj` — exists | Keep, but under §7 naming/out-dir, no longer fixed literals | §7.3 |

Explicit non-targets (v1): JPEG (lossy, needs an encoder, no alpha story — PNG covers
sharing), BMP/TGA (no user benefit over PNG), MP4/GIF *encoding* in Fortran (muxing is an
external `ffmpeg` step printed/executed per §6.3, not a renderer feature), SVG (raster
engine; the OBJ/JSON sidecars are the vector/geometry export).

---

## 4. PPM — Keep, and Add P6

### 4.1 P3 (existing, frozen)

- Keep `framebuffer_save_ppm` byte-for-byte compatible: header `P3\n<W> <H>\n255\n`,
  decimal triplets. It is the golden-file format for P04 §11 / P09 §10 regression tests
  ("static scene reproduces today's `output_render.ppm`") — any change breaks them.
- Document its role honestly in `--help` and README: *debug/golden/interchange*, not
  the file you send someone.

### 4.2 P6 (new, spec)

```
"P6\n" <W> " " <H> "\n255\n"  then W*H*3 raw bytes, row-major, top row first (y=1..height)
```

- Implementation note (planned `renderer.f90` addition, not in this plan's scope to
  write): open with `access='stream', form='unformatted'`, write header as characters,
  then pixels reordered from `pixels(3,x,y)` into a `(3*width)` byte row buffer
  (`character(len=1)` / `integer(int8)` with values wrapped via `modulo(v,256)` —
  Fortran signed bytes need care for values >127; specify `transfer`/unsigned-modulo
  handling and a round-trip test in §10).
- Size: 640×480 P6 ≈ 0.92 MB vs 3.6 MB P3 (≈4×), write time proportionally lower —
  this is the default animation-frame encoding (§6).
- Viewer consequence: fix `viewer.html`'s decoder to actually accept P6 (it advertises
  P6, then rejects non-P3) or drop the claim; P17 requires the claim and the code to agree.

---

## 5. PNG

### 5.1 Phase 1 — via PPM conversion (spec for doing today's hack properly)

Pipeline: render → write PPM (always, it is the canonical intermediate) → convert →
verify the PNG exists and is non-empty → report which converter ran.

| Priority | Converter | Command (exact) | Detection |
|---|---|---|---|
| 1 | ImageMagick | `convert <in>.ppm <out>.png` (IM7: `magick <in>.ppm <out>.png`) | `command -v magick` then `command -v convert` |
| 2 | ffmpeg | `ffmpeg -y -i <in>.ppm <out>.png` | `command -v ffmpeg` |
| 3 | Python (stdlib only — no PIL assumed) | A `tools/png_convert.py` that parses P6/P3 and calls the §5.2 native-spec encoder implemented in Python (`zlib` is stdlib) | `command -v python3` — effectively always available per P04 §8 |

- Selection flag: `--png-converter auto|magick|ffmpeg|python|native|none` (default
  `auto`, order above; `native` once §5.2 exists and then becomes priority 1).
- Failure semantics: converter exits ≠0, missing, or produces a 0-byte file ⇒
  diagnostic `E6xx`-class (P04 §7 emit/IO), exit code `3`, message naming the converter
  tried and the surviving PPM path. Remove the Makefile's bare `|| true`; `make run`
  delegates to the same logic and surfaces the result line:
  `[+] PNG: output_render.png (via magick | native | python-zlib)`.
- Pixel-truth: conversion is lossless PPM→PNG by construction; §10 test decodes the PNG
  and compares every pixel to the `FrameBuffer` PPM.

### 5.2 Phase 2 — native Fortran PNG writer (spec, no external tool at runtime)

PNG needs zlib/DEFLATE, which Fortran stdlib lacks — but DEFLATE *stored* (uncompressed)
blocks are legal zlib, so a dependency-free writer is feasible and fully specified:

```
framebuffer_save_png(fb, filename, ierr)        ! planned, renderer_3d or new output_3d
  signature  89 50 4E 47 0D 0A 1A 0A
  IHDR       width,height (BE int32), bit-depth 8, colour-type 2 (truecolour RGB),
             compression 0, filter 0, interlace 0
  IDAT       zlib stream: header 78 01
             + DEFLATE stored blocks (≤65535 B each: LEN/NLEN, block-final bit on last)
               over scanlines, each scanline = filter byte 00 + W*3 RGB bytes (y=1..H)
             + Adler-32 (BE) of the uncompressed scanline data
  IEND
  every chunk: length(BE) + type + data + CRC-32(type‖data)   ! CRC-32/ISO-HDLC,
             polynomial 0xEDB88320, table built once at first call
```

- Correctness surface is small and testable: two checksums (CRC-32 per chunk, Adler-32
  per stream), big-endian writes via `transfer` to byte arrays + `access='stream'`.
  No `iso_c_binding`, no libpng/libz linkage in the default build.
- Cost: stored blocks ⇒ PNG ≈ raw + ~0.03 % overhead (≈0.93 MB at 640×480 — same as
  P6, larger than compressed PNG). Acceptable for v1 correctness/simplicity; the win is
  *a viewable file with zero tools installed*, not file size.
- Phase 3 (optional, not default): `--png-converter zlib` / build-time `USE_LIBZ`
  linking system zlib via `iso_c_binding` for real compression, or simply preferring an
  external converter when present (auto order already does). Decide only after measuring
  whether users care about PNG size at target resolutions; do not block Phase 2 on it.
- Alpha: colour-type 2 (no alpha) matches the opaque `FrameBuffer`; do not emit type 6
  until the renderer gains an alpha channel (P09 `fade` deferral is the same gap).

---

## 6. Animation Frames

Owned jointly: P09 supplies timeline/fps/duration and the frame loop; this plan supplies
naming, formats and muxing.

### 6.1 Naming — `frame_%04d.ppm` is normative

```
<out-dir>/frames/frame_0000.ppm   frame_0001.ppm   …   frame_NNNN.ppm
pattern: "frame_" + zero-padded decimal(index, width=4) + "." + ext
index:   0-based, contiguous, t = index / fps   (P09 §3 sampling: n = 0 … ⌈D·F⌉−1)
```

- Pattern is a flag, not a constant: `--frame-pattern 'frame_%04d.ppm'` — Fortran has
  no `printf`, so the pattern language is restricted and validated: exactly one
  `%0Nd` (N = 1..8) or `%d`, plus literal text and one extension. Compiler expands it
  with an internal `write(unit,'(A,I0.4,A)')`-style formatter. Anything else ⇒ CLI
  error (exit `2`) before rendering starts, not a bad filename at frame 900.
- Overflow: index > `10^N − 1` (e.g. frame 10000 with `%04d`) widens naturally in
  Fortran's `I0.4` (minimum width, not truncation) — files stay sortable only up to
  9999; validate up front: `ceil(duration*fps) > 9999` with a 4-wide pattern ⇒ warning
  recommending `%06d`. Default pattern for animation mode is `frame_%06d` if the
  computed frame count exceeds 9999, else `frame_%04d`.
- `--start-frame N` (default 0) offsets numbering for chunked/resumed renders;
  `--frame N` / `--time T` (P09 §8) render a *single* frame to the still-image name
  (§7), not into `frames/` — that mode is the parity-test hook and must not create a
  sequence directory.

### 6.2 Formats and defaults for frames

- Default frame format: **P6 PPM** (`--format ppm-p6`), for size/speed (§4.2).
  `ppm-p3` available for debugging/golden comparison; `png` per frame available via
  §5 (native or converter) at predictable extra cost — warn with an estimated total
  (`frames × per-frame bytes`) before starting when the estimate exceeds 500 MB,
  echoing P09 §11's volume warning, with `--yes` to proceed non-interactively.
- Frames land in their own `frames/` sub-directory (never mixed with the still
  outputs), created by the driver — Fortran cannot portably `mkdir`, so directory
  creation is the compiler/driver's job (Python `os.makedirs` in `f3dc`; for the bare
  native binary, `execute_command_line('mkdir -p …')` behind a `--frames-dir` that
  defaults to an already-existing `./frames`, with a clear error if it cannot be made).
- A `frames/manifest.json` is written alongside: `{fps, duration, count, pattern,
  width, height, format, scene}` — the HTML playlist (§8) and the mux step (§6.3)
  consume it; a resumed/chunked run appends rather than rewriting blindly.
- Stale frames: starting a sequence render into a non-empty `frames/` requires
  `--overwrite` (delete higher-index leftovers) or errors — a 120-frame run must never
  silently leave frames 120–199 from a previous 200-frame scene in the mux input.

### 6.3 Mux hint (tooling, not a target)

After a successful sequence, print (and with `--mux mp4|gif` execute) the exact command:

```bash
ffmpeg -framerate <fps> -i <out-dir>/frames/frame_%04d.ppm -c:v libx264 -pix_fmt yuv420p <stem>.mp4
ffmpeg -framerate <fps> -i <out-dir>/frames/frame_%04d.ppm <stem>.gif
```

Absent `ffmpeg` ⇒ print the command as a hint, exit still `0` (mux was not a requested
target) unless `--mux` was explicitly given, in which case it is an `E6xx`/exit `3`.

---

## 7. Output Naming & Defaults

### 7.1 Precedence (highest first — one rule for `engine3d` and `f3dc`)

1. CLI: `--output FILE` (single still) / `--out-dir DIR` + `--name STEM`
2. Source: DSL `output "name"` / `output file.png` statement (P04 keyword list already
   reserves `output`); IR field `RenderCfg.output` (P04 §5.2, today defaulted to
   `"output_render.ppm"` — this plan redefines that default per §7.2)
3. Built-in defaults (§7.2)

An explicit name's extension *selects* the format (`--output hero.png` ⇒ PNG target,
even if `--format` omitted); a conflicting `--format ppm` + `--output hero.png` is a
CLI error, not a silent winner. `--format` accepts a comma list (`ppm,png,html,all`).

### 7.2 Defaults

| Context | Default stem/dir | Default targets |
|---|---|---|
| Native binary, no args (today's behaviour preserved) | `./output_render.*` in CWD | `ppm` **plus** `png` attempted with a visible result line (§5.1) — strict superset of today |
| `f3dc build/run <scene>.f3d` | stem = input stem, dir = `build/` (P04 §10 — never repo root) | `ppm,png,html` + sidecars `scene.json`/`model.obj` |
| Animation (either driver) | stem as above, frames in `<out-dir>/frames/` | `ppm-p6` frames + `manifest.json` + HTML playlist; still targets = frame 0 only if `--poster` given |

Resolution defaults stay as today unless flagged: `--size 640x480` (validate each
dimension ∈ [16, 4096], P04 `E330`), matching `main.f90` and `camera_init` aspect
derivation (`real(width)/real(height)`).

### 7.3 Stem sanitisation and sidecars

- Stem = basename minus last extension; characters outside `[A-Za-z0-9._-]` → `-`;
  empty stem ⇒ `output_render`. Extensions are always lower-case and always written
  by the target (`.ppm/.png/.html`), never inherited from a user string verbatim.
- Sidecars follow the stem in compiler mode: `<stem>.scene.json`, `<stem>.obj` —
  *except* the legacy-compat emit (P04 §6.2) which deliberately writes plain
  `scene.json` into the out-dir so the unmodified current viewer keeps working.
  Native mode keeps today's plain `scene.json`/`model.obj` names (compat), now placed
  under `--out-dir` instead of unconditionally in the CWD.

### 7.4 Overwrite policy

Default: overwrite only files this tool generated before (same names in the target
out-dir) — matching current `status='replace'` behaviour for the native binary's own
`output_render.*`. `f3dc` additionally refuses (per P04 §10) to overwrite a
non-generated `scene.json`/`viewer.html` in the repo root; `--force` overrides,
`--no-clobber` makes *any* existing output an error (CI/golden runs).

---

## 8. HTML Viewer Output

Two modes, one template source (the checked-in `viewer.html` becomes the template —
P04 §6.4 `templates/viewer.html.tmpl`; after P17 the checked-in file should be
*generated from* it, resolving P04 risk (2)):

| Mode | Flag | Contents | Works from `file://`? |
|---|---|---|---|
| Sidecar (default for native) | `--html sidecar` | Emitted `<stem>.html` referencing sibling `<stem>.ppm/.png` and `scene.json` by relative path; fetch paths parameterised instead of today's hard-coded `output_render.ppm`/`output_render.png` | PPM tab: no (fetch/CORS, as today) — viewer must fall back to the PNG `<img>`/canvas path and say why; 3D tab: no. Document "serve with `python3 -m http.server`" in the file itself |
| Self-contained (default for `f3dc`) | `--html inline` | Single file: scene triangles inlined as JS (replacing the hard-coded cube + `fetch('scene.json')`), and the still image inlined as a PNG `data:` URI (or PPM text inlined and fed to the existing JS decoder) — no fetches at all | Yes — this is the shareable artifact and the fix for today's CORS fallback |

- Viewer fixes bundled into the template (output-layer only): real P6 support or
  corrected claim (§4.2), parameterised default filenames, title from scene name,
  triangle-count badge from the actual scene.
- Animation mode: HTML gains a playlist player — `<img>`/canvas flipbook over
  `frames/` via `manifest.json` (sidecar mode), with play/pause + scrub (P09 §8 JS
  evaluator remains the interactive alternative; the flipbook shows the *Fortran*
  frames, which is the point of rendering them). Inline mode for animation inlines
  at most a `--poster` frame — never hundreds of frames into one HTML file.
- HTML is a *view* target, never a correctness target: golden tests assert its
  embedded scene JSON / image hash, not its markup (P04 §11).

---

## 9. CLI Flags (normative table)

Applies to the planned native argument parsing (`get_command_argument` loop in
`main.f90`, planned module `src/cli.f90` or in-driver parsing for `f3dc` — flags,
defaults and exit codes identical so scripts work against either binary).

| Flag | Values / default | Meaning |
|---|---|---|
| `-o, --output FILE` | — | Still-image path; extension selects format (§7.1) |
| `--out-dir DIR` | `.` native / `build/` compiler | Directory for all targets |
| `--name STEM` | `output_render` native / input stem compiler | Stem for derived names (§7.3) |
| `--format LIST` | stills `ppm,png,html`; frames `ppm-p6` | `ppm` (P3), `ppm-p6`, `png`, `html`, `json`, `obj`, `all` |
| `--size WxH` / `--width --height` | `640x480` | Framebuffer size; validated [16,4096] |
| `--png-converter` | `auto` | `auto\|magick\|ffmpeg\|python\|native\|none` (§5) |
| `--frames` / `--animate` | off | Animation mode (with P09 `--fps`, `--duration`) |
| `--fps N`, `--duration S` | `30`, from timeline | Sequence sampling (P09 §3) |
| `--frame-pattern PAT` | `frame_%04d.ppm` (or `%06d`, §6.1) | Restricted pattern language, validated pre-render |
| `--start-frame N` | `0` | Numbering offset for chunked renders |
| `--frame N` / `--time T` | — | Single-frame still mode (P09 parity hook) |
| `--poster` | off | Also emit frame 0 as a still (PNG+PPM) in animation mode |
| `--mux mp4\|gif\|none` | `none` (hint printed) | Run ffmpeg mux after sequence (§6.3) |
| `--html sidecar\|inline\|none` | §8 defaults | Viewer emission mode |
| `--force` / `--no-clobber` | neither | Overwrite policy (§7.4) |
| `--open` | off | Open the HTML/PNG in the OS viewer after success (driver-only; no-op headless with a printed path) |
| `-h, --help` / `--version` | — | Usage incl. target list; unknown flag ⇒ usage + exit `2` |

Exit codes align with P04 §7: `0` ok · `1` scene/source errors · `2` usage/CLI ·
`3` emit/IO/converter failure · `4` build stage failure. Every run ends with a
summary block listing *actual* files written (path, format, bytes, converter used) —
the replacement for today's hard-coded "Output files:" print in `main.f90:62-68`,
which must be generated from what was really written, including failures.

DSL surface: `output` statement mirrors the still flags only —
`output "hero" format png,html size 800x600` — parsed into the same IR `RenderCfg`;
CLI always wins (§7.1). Animation output settings stay timeline-side (P09).

---

## 10. Implementation Shape (planned files, no code here)

```
src/renderer.f90     + framebuffer_save_ppm_p6, + framebuffer_save_png (stored-zlib),
                       all writers gain (fb, filename, ierr) variants; P3 writer untouched
src/output.f90       (new, optional split) format enum + dispatch save_framebuffer(fb, path, fmt, ierr),
                       pattern expansion for frame names, CRC32/Adler32 helpers
src/main.f90           argument loop replacing the literals at :14-18; summary from actual writes
Makefile               run: drop bare `|| true` conversion; report converter result (§5.1)
tools/f3dc/…           emit side reuses §7/§9 verbatim (P04 driver); png_convert.py fallback (§5.1)
viewer.html            becomes generated from templates/viewer.html.tmpl (P04 §6.4)
```

Dispatch rule: emitters/writers never parse flags and flags never write files —
a single resolved `RenderTargets` config (formats × names × sizes) is built once
from §7.1 precedence and passed down, in Fortran as a derived type, in `f3dc` as
the IR `RenderCfg` extension (`formats`, `out_dir`, `frame_pattern`, `html_mode` —
additive, `ir_version` unchanged for stills).

---

## 11. Testing & Acceptance

1. **Golden still:** no-args native run reproduces today's `output_render.ppm`
   byte-identically; the new summary lists it.
2. **PNG truth (both paths):** for converter and native PNG, decode with an
   independent decoder (Python stdlib `zlib` + manual chunk parse, and ImageMagick
   `identify` when present): signature/IHDR (640×480, depth 8, type 2), CRCs valid,
   every pixel equals the PPM. Native writer additionally fuzz-checked at odd
   widths (1, 17, 641 px) to cross stored-block (65535 B) boundaries.
3. **P6 round-trip:** P6 → parse → pixels equal P3 of the same frame; file size
   within 1 % of `W*H*3 + header`.
4. **Naming matrix:** table-driven tests over §7: flag vs DSL vs default precedence,
   extension-selects-format, conflicting `--format`/`--output` ⇒ exit `2`,
   sanitisation cases, `--no-clobber` ⇒ exit `3` with nothing written.
5. **Frames:** 2 s @ 30 fps scene ⇒ exactly 60 files `frame_0000…frame_0059`,
   contiguous, manifest count matches, stale-frame guard fires on a dirty dir,
   `%04d` overflow warning at >9999 frames, single `--frame 7` writes a still and
   no `frames/` directory.
6. **No-silent-failure:** with converters hidden from `PATH` and native PNG
   disabled, `--format png` ⇒ exit `3`, message names the PPM that survives.
   (Direct regression test for today's `|| true`.)
7. **HTML:** inline mode opened from `file://` displays the scene and the still
   with zero network requests; sidecar mode under `http.server` loads parameterised
   (non-default) filenames; embedded image hash equals the emitted PNG's hash.
8. **Determinism:** two identical runs ⇒ identical bytes for PPM/P6/PNG/inline-HTML.

---

## 12. Phased Delivery

| Phase | Deliverable | Usable result |
|---|---|---|
| P17-a | CLI parsing + §7 naming/precedence + honest summary + converter-based PNG (§5.1), Makefile `|| true` removed | `engine3d -o hero.png --size 800x600` works; failures are loud |
| P17-b | P6 writer + viewer P6 fix | 4× smaller/faster frames groundwork; viewer claim becomes true |
| P17-c | Native stored-zlib PNG writer (§5.2) + pixel-truth tests | Viewable PNG with zero external tools; converter becomes an optimisation |
| P17-d | Frame sequences: pattern, `frames/`, manifest, stale guard, mux hint/`--mux` (with P09-a frame loop) | `frame_%04d.ppm` sequences ready for ffmpeg/HTML |
| P17-e | HTML targets: parameterised sidecar + self-contained inline, animation playlist | One shareable `.html` per scene — the ease-goal showpiece |

Risks / open questions: (1) signed-byte handling for P6/PNG stream writes under
`gfortran -fcheck=all` — prototype the row-buffer encoding before committing P17-b/c
estimates; (2) stored-PNG size at 4K stills (≈24 MB) may force the libz phase-3
earlier than planned — measure at 1920×1080 first; (3) `execute_command_line` for
`mkdir`/converters is compiler-portable but not standard-clean — keep all such calls
in the driver/output layer, never in `renderer_3d`; (4) should `png` join the
*no-args native default* (§7.2) before the native writer lands, given converter
availability varies? This plan says yes-with-loud-failure-as-warning for the default
invocation only (requested `--format png` stays a hard error, §11.6) — parent plan
to confirm; (5) `frame_%04d` vs `%06d` default interacts with external tools that
glob-sort — manifest is the authoritative order regardless.
