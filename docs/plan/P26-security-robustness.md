# P26 — Security & Robustness: Limits, Path Safety, Fuzzing, No Code Execution

> **Status:** Planning only — no `src/` code changed by this document.
> **Repo ground truth audited (2026-11-23):** `src/main.f90` (hard-coded
> 640×480 cube demo; no CLI, no parser, no input file), `src/mesh.f90`
> (`Mesh{num_triangles, triangles(:)}`, `create_cube` only, unchecked
> `open(... status='replace')` in `export_mesh_json/obj`),
> `src/camera.f90` (`camera_init` performs **zero validation**),
> `src/renderer.f90` (`framebuffer_init` allocates `pixels(3,width,height)`
> + `z_buffer(width,height)` with no range, overflow, or `stat=` check;
> screen coords via unchecked `int(...)` of projected reals),
> `src/math_3d.f90` (`mat4_perspective`: `tan(fov/2)`, divisions by
> `aspect*tan_half_fov` and `far-near` — all unguarded),
> `Makefile` (`gfortran -O3 -Wall -Wextra -fcheck=all`, zero dependencies),
> `viewer.html` (`fetch('scene.json')` / `fetch('output_render.ppm')`,
> inline `<script>`), repo-root `scene.json` / `model.obj`.
> **Companion plans whose numbers this plan reconciles, not replaces:**
> P03 (grammar, reserved words), P04 (pipeline, 1 MiB source guard,
> `repeat` cap 1,000 / `E401`), P08 (diagnostics, exit codes, no-crash
> sweep), P12 (group depth 1), P14 (textures: 32 files, 4096 px/axis,
> 64 MiB), P15 (OBJ: 64 MB, 4,096-char lines, 1M vertices, 500k faces,
> 1,024 groups/corners), P16 (10,000 placements, 1M triangles/scene),
> P18 (fuzz/truncation sweeps, nightly), P19 (CI), P20 (CLI, captured
> subprocess output).

---

## 0. Verdict in one page

| Decision | Ruling |
|---|---|
| Threat posture | **Every input file is untrusted**, even one the user "just downloaded" or was sent by a friend: `.f3d` scenes, legacy `scene.json`, `.obj` models, `.mtl` names inside OBJ, texture images, CLI arguments, and paths written inside any of them. The compiler is a local, single-user, offline tool — not a network service — but a shared scene folder is a real distribution channel, so file-borne attacks are in scope and network attacks are explicitly out (§1.2). |
| First rule | **Check before you allocate, expand, open, or execute.** Every count that sizes memory, a loop, an expansion, or an output is validated — with overflow-checked arithmetic — *before* the allocation/expansion that trusts it. No limit is enforced after the damage. |
| Limits | **One canonical table (§3), one constants module, hard errors.** Values are inherited from P04/P14/P15/P16 wherever they exist; where siblings disagree the tighter value wins and the conflict is named (§3.3). Exceeding a limit is a compile error naming limit + actual — never truncation, clamping, or partial success. |
| Recursion | **No unbounded recursion anywhere.** Parser nesting is depth-counted (§4); group/repeat nesting keeps P12/P16's structural caps; Fortran runtime stays iterative; emitted code contains no recursion the user can influence. |
| Paths | **Containment, not string filtering.** `load`/texture/include paths resolve relative to the scene file, are canonicalised (symlinks resolved), and must stay inside the scene directory (§5). `..`, absolute paths, and escaping symlinks are errors, not sanitised-away. `mtllib` is never opened (P15). Output paths follow the opposite, stricter rule: write only where the CLI said, only generated files, never over a hand-written file without `--force`. |
| Code execution | **The DSL can never execute anything.** It is declarative data only (P03/P04 non-goal, made enforceable in §6): no `eval`, `system`, `import`, `include`-as-code, shell, environment-variable expansion, string interpolation, network fetch, or user-controlled compiler flags. Emitted Fortran/JSON/HTML is built from typed IR values with escaping — user text is never spliced raw into code, markup, or a shell command line. |
| Numeric safety | Only **finite, in-range** numbers reach the runtime. `NaN`, `Inf`, `1e999`, out-of-`int` magnitudes, and zero/negative sizes are parse/validate errors. This closes today's real holes: unvalidated `camera_init`, unguarded `mat4_perspective` divisions, unchecked `int()` in the rasterizer (§7). |
| Fuzzing | **A release gate, not an aspiration** (§8): truncation at every byte offset, seeded mutation, and grammar-aware generation over `.f3d`/OBJ/JSON/texture inputs. Invariant for every case: bounded time, bounded memory, exit ∈ {0,1,2,3} with a diagnostic, no traceback, no hang, no partial output. Crashers are minimised, added to a permanent regression corpus, and block release. |
| Safe defaults | Secure behaviour is the **zero-flag** behaviour (§9): limits on, containment on, network off (there is no network), subprocess shell off, overwriting off. Escape hatches (`--force`, raising a soft limit) are explicit, single-purpose, printed in the run summary, and can never raise a hard ceiling. |
| Diagnostics | New append-only block **`E80x`–`E82x` / `W80x`** (§10), rendered through P08's single collector: limit errors show the arithmetic, path errors show the resolved path and the boundary it escaped, and no diagnostic ever echoes back more input than P08's snippet rules allow. Internal faults stay `E9000`. |

Non-goals: sandboxing the *user's own* explicitly-named top-level input
(they may compile any file they can read — containment applies to paths
*referenced from inside* a scene, §5.1), cryptography/signing of scenes,
multi-user permissions, a network server mode, and defending against a
malicious `gfortran`/OS (trusted toolchain, §1.3).

---

## 1. Threat model

### 1.1 Assets and harms

| Asset | Harm from a hostile/accidental bad input |
|---|---|
| Host filesystem | A scene references `../../…` or an absolute path and the compiler reads a private file into a diagnostic/output — or, worse, an *output* path overwrites source, documents, or `src/*.f90`. |
| CPU / RAM / disk | A tiny input expands huge: `repeat`×`grid` products (P16), a 64 MB OBJ de-indexing to ~3× soup (P15 §5.1), a 8192×8192 framebuffer, a crafted count that overflows `width*height`. Result: OOM, swap death, disk filled by PPM/frames — the user's machine hangs, which for this project's audience is indistinguishable from malware. |
| Output integrity | A "successful" partial or silently-truncated render teaches the user a wrong picture is correct (P08 §1.5's anti-pattern, in security form). Injection into emitted HTML/JSON/Fortran turns a data value (a scene or object name) into live code in the viewer. |
| Toolchain integrity | A scene value reaching a shell command line or a `gfortran` flag turns compiling a scene into running the scene author's commands. |

### 1.2 In scope / out of scope

- **In:** malformed, oversized, adversarial, or merely weird `.f3d`,
  `.obj`, legacy `.json`, texture, and referenced files; hostile names,
  strings, numbers, and paths inside them; expansion/allocation bombs;
  parser hangs and stack exhaustion; injection into every emit target
  (Fortran, JSON v1/v2, JS, HTML — P04 §6); CLI argument abuse.
- **Out:** network attackers (no listener, no fetch — §6.4 makes this a
  rule, not a current accident), other local users, rootkits, malicious
  compilers, and side channels. If a future plan adds any network or
  server feature, it needs its own threat plan; this one does not
  pre-approve it.

### 1.3 Trust boundaries

```
UNTRUSTED                          TRUSTED
scene folder (.f3d/.obj/.json/  ──▶ compiler (lexer→parse→validate,
 textures, names, paths, counts)    limits+containment enforced HERE)
                                        │ typed IR only
                                        ▼
                                   emitters (escape, never splice)
                                        │
                                        ▼
                                   gfortran + Fortran runtime
                                   (fixed argv, no shell, §6.3)
                                        │
                                        ▼
                                   outputs in build/ (stamped, §5.4)
```

Everything left of the compiler is data. Nothing crosses the boundary
as code, a path that has not been contained, or a count that has not
been checked. The Fortran runtime is trusted *code* but must still
defend its own preconditions (§7.3) because emitted code is generated
from untrusted-derived IR.

---

## 2. Principles

1. **Deny by default, allowlist by name.** Unknown keywords, extensions,
   formats, and statement forms are errors (or P15-style counted
   warnings where a sibling plan already ruled so) — never ignored-and-
   continued in a way that changes meaning.
2. **Validate at the earliest stage that has the facts** (P04 pipeline):
   size at read, syntax at lex/parse, counts and products at
   desugar/validate, paths at resolve, preconditions again at the
   Fortran boundary (defence in depth, P08 §3).
3. **Fail closed, fail whole.** Any limit/path/security error ⇒ no
   render, no partial output file, exit per §10.3. A half-written output
   is deleted or never started (write-to-temp-then-rename, §5.4).
4. **No silent fix-ups of security-relevant values.** No clamping a
   count to the cap, no stripping `../` and continuing, no truncating a
   long line/string. (Beginner-friendly *warnings* for inert fix-ups
   remain P08's business; anything in §§3–6 is an error.)
5. **One constants source.** Every number in §3 lives once, in one
   compiler constants module (and its Fortran mirror where the runtime
   re-checks it), referenced by name in code, tests, and `--explain`
   pages. A limit that exists in two places will diverge.
6. **Bounded everything.** If a loop, allocation, recursion, file, or
   subprocess cannot state its bound from §3, it does not ship.

---

## 3. Canonical limits (the single table)

### 3.1 Input and parser limits

| # | Limit | Value | Source / note | On exceed |
|---|---|---|---|---|
| L1 | `.f3d` source size | **1 MiB** | P04 §4.1 | `E801` |
| L2 | Any single input line | **4,096 chars** | P15 (OBJ); applied to all text inputs | `E801` |
| L3 | Lines per source file | 50,000 | Derived from L1/L2 worst cases; catches newline bombs inside L1 | `E801` |
| L4 | Tokens per file | 200,000 | P04 "max token count", numbered here | `E801` |
| L5 | Identifier length | 64 chars | P03 `name` rule; longer is a typo or an attack on tables/messages | `E802` |
| L6 | String literal length (paths, titles) | 512 chars, no NUL/control chars except tab | Long enough for any real path; bounded for messages/buffers | `E802` |
| L7 | Nesting depth (any block: `scene`/`group`/`repeat`/`grid`/braces) | **16** parser-hard | §4; semantic caps are far lower (L16/L17) | `E803` |
| L8 | Statements per file | 20,000 | Pre-expansion; expansion has its own caps (L17–L19) | `E801` |
| L9 | Diagnostics collected | 10 errors shown | P08 §3.2 (unchanged — itself a limit: no error-spam DoS of the terminal/log) | footer note |
| L10 | Legacy `scene.json` input size | 16 MiB; ≤ 1M triangles, ≤ 3M vertex arrays elements, depth ≤ 32 JSON nesting | Compat reader (P04 §4.1) gets the same treatment as every parser; JSON depth is a classic stack bomb | `E801`/`E803` |

### 3.2 Scene, expansion, and geometry limits

| # | Limit | Value | Source / note | On exceed |
|---|---|---|---|---|
| L11 | Objects before expansion | 10,000 | P16 scene cap, applied pre- and post-expansion | `E403`-family / `E804` |
| L12 | `repeat` count, per statement | **1,000** | P04 §4.3, P16 §8.1 (`E401`) | `E401` |
| L13 | `grid` dimensions | each 1–1,000; product ≤ 10,000 per grid | P16 §8.1 (`E402`) | `E402` |
| L14 | Total placements per scene | **10,000** | P16 §8.1 | `E403` |
| L15 | Total triangles per scene (Σ placements × prototype tris) | **1,000,000** | P16 §8.1, P07 merge cap | `E404` |
| L16 | Group nesting depth (semantic) | **1** | P12 §8 | P12's error |
| L17 | Helper nesting (`repeat{grid{…}}`) | **2** levels | P16 §3.6 | P16's error |
| L18 | OBJ file size / vertices / faces / groups / corners-per-face | 64 MB / 1,000,000 / 500,000 / 1,024 / 1,024 | P15 §4.7 verbatim | `E5106`/`E5103` |
| L19 | Estimated geometry memory (soup expansion) | **256 MiB** pre-flight estimate | §3.4; P15 notes soup ≈ 3× — estimate *before* de-indexing, not after allocating | `E804` |
| L20 | Animation: frames per render / fps / duration | 3,600 frames / 1–240 fps / ≤ 600 s, and frames×pixels ≤ L22 budget | Bounds the frame-sequence disk/CPU bomb (`frames × width × height` is the real cost, so it is the product that is capped) | `E804` |
| L21 | Textures: count / axis / total memory | 32 / 4,096 px / 64 MiB | P14 §6.5 verbatim | P14's codes |
| L22 | Framebuffer: width, height / total pixels | each 16–4,096; **≤ 16,777,216 px** | §3.3 resolves the P04-vs-P08 conflict at 4,096. Memory pre-flight: `(3 int + 1 dp) × pixels` ≈ 20 B/px ⇒ ≤ ~336 MiB worst case is *still* too much by default — see the soft tier, L23 | `E805` |
| L23 | Framebuffer soft tier | > 4,194,304 px (2048×2048) | Warning `W801` + requires explicit `--allow-large` to exceed 8,388,608 px; hard ceiling L22 cannot be raised (§9) | `W801`/`E805` |
| L24 | Numbers: magnitude / exponent as written | finite `real64`; \|value\| ≤ 1e15 for lengths/coords, angles reduced mod 360 after range checks per-property (P08 catalogue) | §7.1; per-property ranges (fov, near/far, colour) remain P08/P03's, unchanged | `E806` |
| L25 | Compiler wall-clock / subprocess timeout | 120 s compile, 300 s `gfortran`+run, per-case fuzz timeout 5 s | §8.4; a timeout is an error (`E807`), never a silent kill-and-succeed | `E807` |

### 3.3 Conflicts found in sibling plans — resolved here

| Conflict | Values | P26 ruling |
|---|---|---|
| Image dimension max | P04 §4.3: 4,096; P08 E3003: 8,192 | **4,096 + pixel-product cap (L22).** 8192×8192 int+dp buffers ≈ 1.3 GiB in today's `FrameBuffer` layout — not a safe default on this project's modest hardware. P08's E3003 text must be amended to 4,096 when implemented; the code (`E3003`) and meaning do not change. |
| OBJ vs scene triangle caps | P15: 500k faces/file; P16: 1M tris/scene | Both stand: per-file (L18) *and* per-scene (L15) checks; two loaded 500k-face files that fan-triangulate past 1M fail at the scene check with both files named. |
| Source cap vs OBJ cap | P04: 1 MiB (`.f3d`); P15: 64 MB (`.obj`) | Both stand — they govern different parsers. The `.f3d` that *references* a 64 MB OBJ stays ≤ 1 MiB. |

### 3.4 Checked arithmetic — the implementation rule behind every cap

- All products/sums that size anything (`nx*ny*nz`, `placements × tris`,
  `width*height`, `frames × pixels`, `vertices × bytes`) are computed
  in 64-bit (compiler) / `integer(int64)` (Fortran) with an explicit
  pre-multiplication overflow test (`a > LIMIT / b`), never by
  computing in 32-bit and checking afterwards. Today's Fortran default
  `integer` is 32-bit: `width*height` for the framebuffer and
  `num_triangles` arithmetic must be widened *before* use (§7.3).
- Expansion is **counted before it is performed**: desugar first
  evaluates the arithmetic tree of counts (P16 §8.2 order: per-helper,
  then products, then scene totals) and only expands if all checks
  pass. Memory estimate (L19) uses a named bytes-per-`Triangle`
  constant matching `mesh.f90`'s type, reviewed when that type changes.
- Allocation failure is a diagnostic, not a crash: every Fortran
  `allocate` gains `stat=`; every compiler allocation path that can
  fail maps to `E804` with the estimate in the message.

---

## 4. Recursion and nesting

| Site | Rule |
|---|---|
| Lexer/parser | Hand-written recursive descent (P04 §4.2) carries an explicit `depth` counter incremented on every block entry; L7 (16) is checked *before* recursing. 10,000 `{` on one line is `E803`, not a stack overflow — in Python *or* Fortran implementations; neither language's default recursion/stack limit is part of the design. |
| Grammar-aware fuzz + JSON compat reader | Same counter; JSON nesting ≤ 32 (L10) checked iteratively/explicitly, not by trusting the stdlib parser's limit (set it where configurable *and* pre-scan depth cheaply). |
| Desugar/validate/optimize | Tree walks over AST/IR are bounded by L7 depth and L8/L11 node counts; any walk that could revisit nodes (name resolution, group flattening) is iterative over the flat statement/object lists P12 mandates — the flat scene model (P12: no general hierarchy, no cycles by construction) is retained precisely because it makes cycles unrepresentable. Do not add parent pointers or user-defined references that could create a cycle without amending this plan. |
| Fortran runtime | No recursive procedures in `src/`; none may be added for scene-controlled structures. Emitted Fortran is straight-line + counted loops only (§6.2). |
| Name/reference resolution | References resolve to earlier definitions only (P03 target rule); forward/self reference chains are therefore finite by construction and need no visited-set — state this invariant in the validator and test it (§11). |

---

## 5. Path safety: load, texture, output

### 5.1 Containment rule (referenced inputs)

For every path that originates *inside* an input file — DSL `load
"…"` (P15 §6), `texture: "…"` (P14 §6.4), `export`/render targets
written in a scene, OBJ group/material names used as filenames
(never, §5.3), and legacy JSON fields naming files:

1. **Form checks first:** must be a quoted relative path (P14 §6.4);
   reject absolute paths, `~`, drive/UNC forms, backslashes on any
   platform (one canonical `/` form — no platform-dependent parsing
   differences to exploit), NUL/control characters, empty path, and
   any `..` component — rejected as written, not normalised away.
2. **Resolve:** join to the *scene file's directory* (never the process
   CWD — P15 §6.4), then canonicalise: resolve `.` components and
   **all symlinks** (`realpath` equivalent) for the file and its
   parent chain.
3. **Contain:** the canonical result must be the scene directory or a
   descendant of its canonical form. A symlink inside the scene that
   points outside fails here even though step 1 passed — string checks
   alone do not stop symlink escapes, which is why this step exists.
   TOCTOU note: the window between check and `open` is accepted for a
   local single-user tool and recorded as such; it is *not* accepted
   as a reason to skip the check.
4. **Type checks:** must exist, be a regular file (not a directory,
   device, FIFO, or socket), and carry an allowlisted extension for
   its role (`.obj` for load, P14's format table for textures).
   Extension *and* magic sniff must agree or warn per P14 §6.2.
5. **Report:** errors (`E810`) print the path as written, the resolved
   absolute path tried, and the boundary ("inside your scene folder
   `…`") — P08 §8.8 cwd-honesty applied to containment.

The user's *top-level* CLI input (`f3dc run scene.f3d`) is exempt from
containment — naming it was the user's own act — but every path that
file then pulls in is not. Included/nested scene files, if a future
grammar adds them, inherit containment from the root scene's directory.

### 5.2 Reads: what may never be opened

- `mtllib` targets: **never opened** (P15 §4.6) — a hostile OBJ must
  not be able to cause *any* additional file access.
- `.mtl`, texture, or model files discovered by *scanning* a directory:
  none. The compiler opens exactly the files named, after §5.1.
- No file is opened during lex/parse of another file; all referenced
  reads happen in validate/load stages where §3 size caps are applied
  *from file metadata before reading the body* (a 10 GB "OBJ" fails
  L18 on size without being read into memory).

### 5.3 Names are not paths

Object/group/material/scene names (P15 §4.5 sanitising, P03 `name`
rule) are identifiers, never used as filenames by the compiler or
emitters except for the P04 stem-derived outputs — and there the stem
is sanitised to `[A-Za-z0-9._-]` with leading dots stripped before use.
A group literally named `../../evil` loads as object `evil` (P15
sanitiser) and writes nothing under that name.

### 5.4 Output paths (writes are the dangerous direction)

| Rule | Detail |
|---|---|
| Default location | `build/` under the CWD (P04 §10), created if absent; scene-specified output names are *basenames only* inside the chosen out-dir — a scene cannot redirect its own render to an absolute or parent path. CLI `--out` is the user's act and is exempt from containment but not from the rows below. |
| No clobber | Overwrite only files bearing the `f3dc` generated stamp, or with `--force` (P04). Never overwrite any `src/*.f90`, the input scene, or a file whose extension is not an output extension for the selected target (`.ppm/.json/.obj/.html/.js/.f90` in out-dir). |
| Atomicity | Write to `<name>.tmp-<pid>` in the same directory, close successfully, then rename. Any error mid-emit ⇒ temp removed, previous good output untouched, no partial file presented as success (P04 §10, P15 §6.4). |
| Symlinks | If the output path exists as a symlink, refuse (`E811`) rather than follow it — the stamp check reads the *target*, which is exactly the confusion an attacker wants. |
| Frame sequences | Numbered frames (P03 §7) are generated names only (`<stem>_0001.ppm`, …), count bounded by L20, all inside the out-dir. |
| Fortran runtime outputs | Today's `export_mesh_json/obj` and `framebuffer_save_ppm` use unchecked `open(status='replace')`: the runtime hardening in §7.3 adds `iostat=` + the same no-clobber/stamp contract when driven by the compiler; the hard-coded demo paths in `main.f90` are developer outputs, not scene-controlled, and stay as-is. |

### 5.5 Viewer / browser surface

`viewer.html` `fetch()`es only the two fixed sibling names it already
uses; generated HTML (P04 §6.4) inlines scene data as *data* (§6.2
escaping) and must not gain a fetch of any scene-supplied URL. A scene
name rendered into a page title is text content, escaped — never markup.

---

## 6. No code execution in the DSL

### 6.1 Language-level guarantees (grammar enforcement)

- The DSL stays **declarative and non-Turing-complete** (P03 §11,
  P04 §1): no variables with computed values beyond the bounded
  arithmetic P04 allows, no functions, no conditionals that select
  statements at "runtime", no unbounded loops — `repeat`/`grid` are
  counted expansions under §§3–4, not loops over user state.
- Reserved-and-rejected words (P03: `let if for loop function import
  texture material` in v1, plus this plan adds) `system exec shell
  eval include run command env url fetch download plugin` lex fine and
  fail with a targeted `E820`: *"`system` is not part of the language —
  a scene describes a picture; it cannot run commands."* Reserving
  them prevents both accidents and a future dialect quietly adding
  an execution feature under an innocent name.
- **No expansion of any kind inside strings:** no `$VAR`, `${…}`,
  backticks, `%ENV%`, `~` expansion, or escape sequences that decode
  to path separators/control characters. A string is its literal
  characters (P03: no escapes in v1) from lexer to path resolver.
- **No network, ever:** no URL is a valid path (§5.1), no stage fetches
  anything, and the compiler must work fully offline. `http:` in a
  path position is `E810` with that sentence as the help text.

### 6.2 Emitted-code injection

| Target | Rule |
|---|---|
| Fortran (`.f90`) | Built only from typed IR: numbers formatted by the emitter's fixed formatter, colours as integer literals, names emitted only as *comments or validated identifiers* (L5 charset), file paths emitted as string literals with internal quotes doubled per Fortran rules **and** already containment-checked. No raw source line is ever copied into emitted code. Golden tests include a scene whose name/title contains `'`, `!`, newline-attempts, and Fortran keywords (§11). |
| JSON (v1/v2) | Produced by a real serialiser (stdlib `json`), never string concatenation — the failure mode visible in today's hand-formatted `export_mesh_json` must not be replicated compiler-side. Strings escape per JSON spec; `</script>` sequences are additionally `\u003c`-escaped in the JS/HTML targets. |
| JS / HTML | Scene/object names and titles are data values in a JSON blob, assigned via `textContent`-equivalent paths in the template, never interpolated into executable JS source or `innerHTML`. Template substitution (P04 §6.4) substitutes *escaped* values into named slots only. |
| OBJ export | Names written into `o`/`g` lines are the sanitised identifiers of §5.3; a name containing a newline is impossible by L5/L6 and is asserted, not assumed, in the emitter test. |

### 6.3 Subprocess safety (the compiler driving `gfortran`)

P04 stage 6 / P20 §3.5, hardened: subprocesses are invoked with an
**argv array, never a shell** (no `shell=True`, no `os.system`, no
string-built command lines); the compiler binary and flags are the
fixed list from the `Makefile` (`-O3 -Wall -Wextra -fcheck=all`) —
**no scene content, CLI free-text, or environment variable may add,
remove, or alter a compiler flag**, and user input filenames enter
argv only as single, already-validated elements beginning after a
`--`-style separator where the tool supports it. Environment passed
to subprocesses is the inherited environment *minus* any variable the
build does not need that can redirect code loading (`LD_PRELOAD`,
`LD_LIBRARY_PATH`, Python's `PYTHONPATH`/`PYTHONSTARTUP` for the
compiler's own interpreter are documented as operator responsibility,
not scene-controllable). Captured output is size-capped (1 MiB shown,
rest summarised) so a hostile scene cannot flood logs via `gfortran`.

### 6.4 What this does *not* forbid

The user explicitly running `f3dc run` *is* choosing to execute the
trusted Fortran runtime on their data — that is the product. What is
forbidden is the *data choosing* what executes. `--fix`, plugins,
hooks, post-build commands, and config-file command strings are out
of scope for v1 and require a plan amendment, not a flag, if proposed.

---

## 7. Numeric and runtime robustness (Fortran boundary)

### 7.1 Number parsing

- Lexer accepts only P03/P04 number forms; parser converts with checked
  conversion (Python: `float()` guarded + `math.isfinite`; Fortran:
  internal `read(...,iostat=)` + `ieee_arithmetic` `ieee_is_finite`,
  exactly as P15 §8.2 rules for OBJ). `nan`, `inf`, `infinity` in any
  case, hex floats, and overflowing literals (`1e999` → `Inf`) are
  `E806`, never values.
- Integer fields (counts, sizes, colour channels, indices) parse as
  integers only: `3.0`, `1e3`, and values outside 32-bit range where
  the field is 32-bit are errors, not truncations (P15's index rule,
  generalised). Colour channels keep P08's 0–255 `E3002`.
- Every per-property range in P03 §4.1 / P08 §6.2 stands (fov, near<far,
  size>0, …); P26 adds the cross-field products of §3.4 and L24's
  magnitude ceiling so individually-legal values cannot combine into
  an overflow downstream.

### 7.2 Floating-point behaviour in the runtime

- Reject non-finite *derived* values at validate time where checkable
  (camera `at == look`, zero light direction — P04 `E340`), and guard
  the rest in Fortran (§7.3): after projection, a vertex whose clip
  `w` is ~0 or whose NDC coords are non-finite is skipped per-triangle,
  never `int()`-converted.
- Screen-coordinate conversion happens only after finiteness + range
  checks, with saturation to a bounded off-screen range (e.g. clamp
  to ±2× framebuffer extent *before* `int()`), so a vertex at 1e300
  cannot trigger undefined integer conversion. The existing barycentric
  denominator guard (`abs(denom) < 1e-6`, `renderer.f90`) is the model
  for this style and stays.

### 7.3 Required runtime guards (for the implementing agent; `src/` is
changed by that work, not by this plan)

| Site today | Guard to add |
|---|---|
| `framebuffer_init` (`renderer.f90`): unchecked `allocate` of `pixels`/`z_buffer` | Validate `16 ≤ w,h ≤ 4096` and pixel product (int64 arithmetic) before allocating; `allocate(..., stat=)` → clean error return, never an abort. Signature grows an error out-param or the compiler-side check is duplicated here per P08 §3 defence-in-depth. |
| `camera_init` (`camera.f90`): no validation | Re-check fov ∈ (0,180), `0 < near < far`, `aspect > 0` finite, `pos ≠ target`; on failure report through the diag sink (P08 Phase 1 already plans exactly this — P26 makes it a security requirement, not only UX). |
| `mat4_perspective` (`math_3d.f90`) | Callers guarantee §7.3-camera preconditions; add an internal guard for `far == near` / `tan_half ≈ 0` returning identity + error flag rather than Inf/NaN matrices, so no future caller can poison every vertex silently. |
| `framebuffer_render_mesh` / `draw_triangle` | §7.2 finite/clamp-before-`int()` rule; loop bounds derive only from the already-validated framebuffer size and clamped coords. |
| `export_mesh_json/obj`, `framebuffer_save_ppm` | `open(..., iostat=)` checked, failure reported with the path; no `status='replace'` on a path that failed §5.4's checks when compiler-driven. |
| Build flags | Keep `-fcheck=all` in the shipped `Makefile` build until a measured release profile is separately justified; fuzz builds (§8.3) add `-fsanitize=address,undefined -g -O1` as a *separate* target, never replacing the default. |

---

## 8. Malformed-input fuzzing

### 8.1 Corpora (seed inputs, all committed under the test tree)

Valid minimal + maximal scenes (P03 §9 examples, P16 headline cases),
the repo `model.obj`/`scene.json`, one fixture per P08/P15 error code,
P14 texture fixtures, and **every crasher ever found** (minimised,
§8.5). Seeds live with P18's layout (`tests/fuzz/corpus/<format>/`).

### 8.2 Generators — three complementary strategies

| Strategy | Method | Catches |
|---|---|---|
| Truncation | Every seed cut at **every byte offset** (P08 §10.3, P15 §10.10, P18 sweeps) | EOF handling, half-token/half-face states, "accepted a prefix and rendered it" |
| Mutation | Seeded PRNG: byte flips, token swaps/deletions/duplications, number-field replacement from a hostile-number dictionary (`0`, `-1`, `2^31±1`, `1e999`, `nan`, `inf`, 10,000-digit literals, empty fields, `//` corner forms for OBJ) | Range checks, index resolution, checked arithmetic, diagnostic caps |
| Grammar-aware generation | Random *syntactically plausible* scenes from the P03/P04 grammar with adversarial parameters: nesting to depth 15/16/17, `repeat`/`grid` at cap±1, products just over L14/L15, paths from a hostile-path dictionary (`../`, `a/../../b`, absolute, `//`, trailing `/`, NUL-in-string attempts, 513-char strings, symlink fixtures created by the harness) | The semantic layer pure mutation rarely reaches: expansion arithmetic, containment, depth |

Deterministic seeds, printed in CI logs; a failure reproduces from
`seed + corpus id` alone. Randomness never comes from wall-clock.

### 8.3 Harnesses and oracles

- **Compiler harness:** run `f3dc check`/`build` on the case in a
  temp dir with a prepared symlink fixture tree; assert the §8.4
  invariant. Python side runs with tracebacks treated as *failures*
  (any unhandled exception = a bug, filed as `E9000`-class).
- **Fortran harness:** the OBJ loader + runtime guards exercised by a
  dedicated fuzz binary built with `-fsanitize=address,undefined
  -fcheck=all -g -O1`; ASan/UBSan output = failure. Where ASan is
  unavailable in CI, the `-fcheck=all` build + exit/output assertions
  are the floor, and the gap is recorded in P19's CI matrix.
- **Texture decoders** (when P14 lands): same treatment per format —
  truncated/corrupt headers are the highest-risk parser in the system
  after OBJ and get their own corpus directory from day one.

### 8.4 The invariant (every case, no exceptions)

```
exit ∈ {0,1,2,3}  ∧  (exit=0 ⇒ outputs complete & within §3 budgets)
∧  no traceback / no ASan-UBSan report / no core dump
∧  wall-clock ≤ 5 s  ∧  peak RSS ≤ 512 MiB (measured by the harness)
∧  no file created outside the case's temp out-dir   ← §5, machine-checked
∧  no file inside the temp scene dir modified
∧  diagnostics ≤ P08 caps, on stderr, plain-mode clean
```

The last two filesystem assertions are what turn §5 from prose into a
test: the harness snapshots the fixture tree (paths + hashes) before
and after every case.

### 8.5 Triage loop and cadence

Crash/hang/OOM/invariant failure ⇒ minimise (byte-ddmin against the
oracle) ⇒ add minimised case to the regression corpus *in the same
change* as the fix ⇒ code assigned from §10 and an `--explain` note if
a new failure mode was accepted-as-error. Cadence follows P18: PR CI
runs corpus regression (fast, deterministic subset), nightly runs the
full truncation + mutation sweeps (< 5 min budget, P18 §2), and a
release requires a clean nightly (§11).

---

## 9. Safe defaults and escape hatches

| Behaviour | Default (zero flags) | Escape hatch | Hatch rules |
|---|---|---|---|
| All §3 limits | On, at table values | `--max-<name> N` may **lower** any limit freely; may raise a *soft* limit (L23, L13 products within hard caps) only with the new value printed in the summary | Hard ceilings (L1, L7, L14, L15, L18, L22, §5 containment) **cannot be raised by any flag, env var, or config file** in v1 |
| Warnings | Shown, non-blocking (P08) | `--strict` promotes to errors | Never the reverse: no flag demotes a §3/§5/§6 error to a warning (`--warn-textures`, P14 §8.2, is the sole grandfathered exception and drops data rather than weakening a check) |
| Overwriting outputs | Stamp-or-refuse (§5.4) | `--force` | Per-run only; never persisted in config |
| Path containment | On | **None** | A scene that needs files outside its folder must have them copied in — the error says exactly that |
| Network | Absent | **None** | §6.1 |
| Subprocess shell | Absent (argv only) | **None** | §6.3 |
| Verbose internals | Off | `-v`/`-vv` (P20) | Verbosity may *show* resolved paths/counts; it may not include file *contents* of referenced models/textures beyond P08 snippet rules |

Config files and environment variables, if P20 adds them, inherit
this section: they may select among defaults but may not widen any
hard limit or disable containment, and the effective limit set is
printable (`f3dc check --print-limits`) so a build is never silently
running under weakened rules someone else configured.

---

## 10. Diagnostics and exit behaviour (new codes, append-only per P08 §6.1)

### 10.1 Proposed codes (`8xx` block was unused by P03–P20 at audit time)

| Code | Meaning | Sev |
|---|---|---|
| `E801` | Input too large: file size / lines / tokens / statements over §3.1 (names the limit, actual, and unit) | error |
| `E802` | Identifier/string too long or containing forbidden control characters | error |
| `E803` | Nesting too deep (shows depth and L7; help shows how to flatten with `repeat`/separate scenes) | error |
| `E804` | Scene too large after counting: placements/triangles/estimated memory over L14/L15/L19 — message shows the full arithmetic, P16 §8 style | error |
| `E805` | Framebuffer too large (dimensions or pixel product over L22) | error |
| `E806` | Number not usable: non-finite, overflowing literal, or magnitude over L24 (banned-word rule: user text says "this number is too big for the engine to store exactly", not "malformed") | error |
| `E807` | Compilation/render step timed out (L25; names the step and the limit) | error |
| `E810` | Path not allowed: absolute/`..`/URL/escaping symlink/containment failure (§5.1; shows written path, resolved path, boundary) | error |
| `E811` | Output not written: would overwrite a non-generated file, is a symlink, or extension not allowed for the target (§5.4) | error |
| `E820` | Forbidden word used: the DSL cannot execute code (§6.1; names the word and what the language does instead) | error |
| `W801` | Large render ahead: framebuffer in L23's soft tier (states pixels and estimated memory/time so the user chooses knowingly) | warning |
| `W802` | Limit raised by flag for this run (echoes old → new value; appears in the footer summary) | warning |

Each code needs a P08 §6.3 `--explain` page before the feature ships;
wording follows P08 §9 (no "invalid"/"malformed" in user text).

### 10.2 Interaction with existing codes

Per-helper/scene expansion keeps P16's `E401`–`E404` (not renumbered
to `E804`; `E804` covers the aggregate/memory cases P16 did not
assign). OBJ limits keep P15's `E5106` family. P26 codes are only for
checks no sibling plan already owns — one check, one code, everywhere.

### 10.3 Exit codes

Unchanged from P08 §7 / P04 §7: `0` rendered, `1` scene errors
(includes `E80x`/`E82x`), `2` CLI misuse, `3` IO failure (includes
`E810`/`E811` when the cause is filesystem access), internal fault
stays the documented `E9000` path. A timeout (`E807`) exits `1` with
the partial output removed (§2.3).

---

## 11. Acceptance tests (all must exist before "done")

1. **Limit boundary suite:** for every row of §3.1–§3.2, fixtures at
   cap−1 (passes), cap (passes), cap+1 (fails with the named code and
   the arithmetic in the message) — including the multiplicative cases:
   `repeat 1000 { grid 10 10 }` product, two-OBJ scene total, and
   `frames × pixels`.
2. **Overflow probes:** counts/sizes whose 32-bit product overflows
   but whose factors are individually legal (e.g. width/height pairs,
   repeat products) fail cleanly with `E804`/`E805` — never allocate,
   never wrap to a small positive size.
3. **Depth probes:** nesting at 16 passes, 17 fails `E803`; 100k
   open-braces on one line fails `E803` within the fuzz timeout, no
   stack trace, in both compiler and JSON-compat paths.
4. **Path corpus:** `../x.obj`, `a/../../x.obj`, `/abs/x.obj`,
   `//server/x`, `C:\x`, backslash forms, empty string, 513-char path,
   a symlink inside the scene pointing outside, a symlinked scene
   subdir pointing outside, and a legitimate nested `models/car.obj`
   (passes) — each asserting code, resolved path in the message, and
   **zero opens outside the scene dir** (harness syscall/log check or
   the §8.4 tree snapshot).
5. **Output safety:** scene asking to render to `../out.ppm`,
   `/tmp/out.ppm`, `src/main.f90`, and over a pre-existing
   non-stamped `scene.json` ⇒ `E811`, target file byte-unchanged;
   stamped output + `--force` paths pass; a mid-emit failure leaves
   no partial file (§5.4 atomicity test).
6. **No-exec corpus:** scenes containing `system`, `eval`, `import`,
   backticks, `$(...)`, `${HOME}`, a URL texture, and a `load` of a
   file whose *contents* are a shell script ⇒ `E820`/`E810` as
   applicable, and the harness asserts no unexpected process was
   spawned and no marker file the payload names was created.
7. **Injection corpus:** names/titles/strings containing `'`, `"`,
   `</script>`, `<!--`, newlines, Fortran comment starters, and JSON
   metacharacters compile to outputs that (a) pass `gfortran
   -fsyntax-only`, (b) parse as valid JSON, (c) load in the viewer
   with the string shown as inert text.
8. **Hostile numbers:** `nan`/`inf` spellings, `1e999`, 10,000-digit
   literal, `-0`, colour `256`, index/count `2147483648`, fov/near/far
   edge pairs ⇒ named errors; plus a runtime test that a projected
   vertex at ±1e300 is skipped, not crashed on (§7.2).
9. **Fuzz gates:** §8.4 invariant holds over (a) full truncation of
   every seed, (b) 10,000 seeded mutation cases per format, (c) 1,000
   grammar-generated adversarial scenes — in CI-nightly configuration;
   the PR subset (§8.5) is green on the merge commit.
10. **Runtime guards:** direct Fortran unit tests calling
    `framebuffer_init`/`camera_init` with illegal values (0, negative,
    4097, `near ≥ far`, `pos == target`) return errors, allocate
    nothing, and never abort the test process.
11. **Defaults audit:** with no flags, `--print-limits` output matches
    §3 exactly; a config/env attempt to raise a hard ceiling is
    refused and reported (`W802` cannot be produced for a hard limit).
12. **Regression anchor:** the P03 3-line scene and the current
    hard-coded demo still produce the baseline render (P18 Phase 0) —
    robustness work must not change a single legitimate pixel.

---

## 12. Implementation sequence

| # | Milestone | Contents | Exit test |
|---|---|---|---|
| S1 | Limits skeleton | Constants module (§2.5), read-size/line/token/depth checks (L1–L10), checked-arithmetic helpers, `E801`–`E803`/`E806` + explain pages | §11.1 (parser rows), §11.3, §11.8 (literal cases) |
| S2 | Expansion & allocation budgets | Count-before-expand (§3.4), L11–L15/L19–L23 enforcement, Fortran runtime guards (§7.3) | §11.1 (product rows), §11.2, §11.10 |
| S3 | Path & output safety | §5.1 resolver + containment, §5.4 atomic/stamped outputs, `E810`/`E811`, `mtllib` never-open assertion test | §11.4, §11.5 |
| S4 | No-exec & injection hardening | §6.1 reserved words, argv-only driver (§6.3), serialiser-only emit + escaping (§6.2) | §11.6, §11.7 |
| S5 | Fuzz infrastructure | Corpora + three generators (§8.2), compiler & Fortran-sanitizer harnesses, invariant oracle incl. filesystem snapshots, nightly CI wiring (P18/P19) | §11.9 |
| S6 | Defaults audit & docs | `--print-limits`, hatch rules (§9), manual chapter ("sharing scenes safely": what a scene can/cannot do, in beginner words), banned-word lint over new templates | §11.11, §11.12 |

S1–S2 should land with the first parser (P04-a/b): retrofitting limits
after users have scenes that exceed them turns a security fix into a
breaking change. S5's corpus regression subset gates PRs from its
first day; the full nightly may ramp up over the following week.

---

## 13. Risks & open questions

- **Limits will reject some legitimate future scene** (a genuinely
  huge architectural model, an 8K poster render). That is the design
  working: the answer is a considered plan amendment raising a *hard*
  ceiling with its memory arithmetic redone — not a per-user override
  that quietly becomes the de-facto limit.
- **Pixel-product cap vs P08's 8192 (§3.3)** needs the P08 owner's
  sign-off at implementation time; if 8192 is ever restored it must
  come with a streaming/tiled framebuffer, because today's
  `pixels(3,w,h)` + `z_buffer(w,h)` layout cannot hold it safely.
- **Symlink containment on case-insensitive / network filesystems**
  can make canonical-path comparison unreliable (case folding, `..`
  in server-resolved paths). v1 targets local Linux filesystems (the
  project's platform); scenes on exotic mounts get the string checks
  plus a documented weaker guarantee, stated in the manual — not a
  silent assumption of strength.
- **Python recursion in `json` for the compat reader** is a stdlib
  behaviour, not fully configurable on all versions; L10's pre-scan
  (§4) is the mitigation, and its test (§11.3) must run on the minimum
  supported Python, not only the developer's.
- **`gfortran` sanitizer availability** varies by distro; §8.3's floor
  (assertions + `-fcheck=all`) must be what CI *requires*, with ASan
  as a required job only where P19 can guarantee the toolchain.
- **Timeouts (L25) are machine-dependent.** They are a backstop
  against pathological hangs, not a correctness mechanism: every
  legitimate bound in §3 must fire *before* a timeout on any hardware,
  and a test that only passes by hitting `E807` is a failing test.
