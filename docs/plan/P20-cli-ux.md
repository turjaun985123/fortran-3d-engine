# P20 — Packaging & CLI UX: `f3dc`, One Command to a Picture

> **Goal linkage:** "Unbelievably easy." P03 defines the `.f3d` language, P04 the
> compiler pipeline and a first CLI sketch, P08 the diagnostics. **P20 owns the
> surface a user actually touches:** installation, the five commands
> (`new` / `build` / `run` / `check` / `fmt`), zero-config defaults, help,
> terminal behaviour, and exit codes. If P03–P08 succeed and P20 fails, the
> project still feels hard — nobody ever reaches the language.
>
> Status: planning only. No code in this document is implemented, and this
> plan changes no file under `src/`.

---

## 0. Ground truth today (verified in this repo, 2026-11-23)

| Fact | Where |
|---|---|
| There is **no CLI at all**: no flags, no subcommands, no `--help`, no version | — |
| The only entry point is `make run`, which builds `bin/engine3d` and runs a **hard-coded** demo: cube size 2, 640×480, camera `(3, 2.5, 4)→(0,0,0)`, fov 60, near 0.1, far 100, light `(-0.5, -1, -0.7)`, rotation 35° Y / 20° X | `Makefile`, `src/main.f90` |
| Outputs land in the repo root with fixed names: `output_render.ppm` (+ `output_render.png` iff ImageMagick `convert` happens to exist — silently skipped otherwise), `scene.json`, `model.obj` | `Makefile` (`run`), `src/main.f90` |
| Build is 5 hand-written `gfortran` rules, flags `-O3 -Wall -Wextra -fcheck=all -Jinclude`, module order math → mesh/camera → renderer → main; dirs `obj/`, `include/`, `bin/` are created as a side effect | `Makefile` |
| There is no install target, no `PREFIX`, no uninstall, no packaging, no release artifact | `Makefile` |
| Checked-in artifacts a new tool must never silently clobber: `scene.json`, `model.obj`, `viewer.html`, `output_render.ppm/png` in the repo root | repo root |
| Toolchain a user must already have, undocumented as a set: `gfortran`, `make`, and (per P04) `python3 ≥ 3.10` | `README.md` (partial) |

**The bar (from P04 §10, kept verbatim as P20's contract):** Three.js
hello-cube ≈ create project, install, import, ~40 lines, dev server.
`f3dc` must be: install once, write ≤ 6 lines, **one command**, open a file.
No project scaffolding ceremony, no manifest, no server, no config file
required — ever — for the common path.

### 0.1 North-star metrics (acceptance, not aspirations)

| Metric | Target | How measured |
|---|---|---|
| Install → first rendered image, new user following only `--help`/README | ≤ 5 min, ≤ 3 commands after install | Timed clean-VM walkthrough (§11) |
| `new` → first image | 1 command to scaffold, 1 to run (§8.2) | Transcript test T2 |
| Existing single-`.f3d` folder → image | **1 command, 0 arguments:** `f3dc` | Transcript test T3 |
| Valid scene, zero flags | `f3dc run scene.f3d` needs nothing else — no `--out`, `--target`, size, or camera flag | Golden tests |
| Broken scene → understandable fix | P08's 10-second test, from the *CLI's* output alone | P08 §8 fixtures via CLI |
| Scriptability | Every failure mode distinguishable by exit code alone (§7); all diagnostics copyable to a file with `2>` | Exit-code matrix tests |
| Help self-sufficiency | Every command's `--help` contains a runnable example; no example in any help text may fail | Help-example tests (§11.4) |

---

## 1. Design principles

1. **The bare command does the obvious thing.** `f3dc` with no arguments in a
   folder containing exactly one `.f3d` file *runs it* (§3.1). `f3dc scene.f3d`
   also runs it. A first-time user who guesses either form succeeds.
2. **Zero config, sane defaults, escape hatches in that order.** No
   `f3d.toml`, no manifest, no `init` step is required. An optional config
   file exists (§4.3) only for people who go looking for it.
3. **Defaults are the demo's defaults.** Every default value is copied from
   the working `src/main.f90` (§4.1), so a zero-flag render looks like the
   demo that already works — omission never produces a black frame or an error.
4. **One command, one job, one summary line.** Each command ends with exactly
   one human summary on stdout: what happened, where the output is, what to
   do next. Verbose detail goes to stderr or behind `-v`.
5. **Never clobber, never surprise.** Generated files go to `build/` by
   default (P04 §10); overwriting a file `f3dc` did not generate requires
   `--force`; writes are atomic (temp file + rename).
6. **stdout is data, stderr is talk.** Results and requested dumps on stdout;
   progress, diagnostics, and hints on stderr (P08 §5.2). Piping stdout never
   captures chatter; `2>errors.txt` always works.
7. **No colour, no TTY, no problem.** Colour/progress/spinners only on a TTY
   with `NO_COLOR` unset; piped output is byte-for-byte as informative
   (P08 §5.3). CI is a first-class environment, not an afterthought.
8. **Fail with the fix.** Every error message names the next command to run
   (`f3dc doctor`, `f3dc check …`, the corrected invocation). A dead end is
   a UX bug, filed against this plan.
9. **Boring technology for distribution.** Python 3 stdlib only (P04 §8 hard
   rule: no `pip install`, ever, for the core tool), one installable file,
   `make install` for repo users. No npm, no virtualenv, no network at
   install or run time.
10. **Stable surface.** Command names, flag names, default paths, and exit
    codes, once shipped in a release, change only with a major version and a
    migration note in `--help` of the old spelling (kept as an alias ≥ 1 release).

---

## 2. Command map

```
f3dc — compile and run .f3d scenes, the easy way

USAGE
  f3dc                        run the only .f3d file in this folder
  f3dc <scene.f3d>            same as: f3dc run <scene.f3d>
  f3dc <command> [options] [file]

COMMANDS
  new <name>        create <name>.f3d from the starter template (nothing else)
  check <file>      validate only — no files written
  build <file>      compile to build/ (Fortran + JSON + JS + HTML)
  run <file>        build, compile with gfortran, render, report the image
  fmt <file>        rewrite <file> in canonical style (--check / --diff for CI)

META
  doctor            check python3 / gfortran / engine files; print fixes
  --version         print "f3dc 0.1.0" (and engine path with -v)
  --help            this text;  f3dc <command> --help for per-command help

EXAMPLES
  f3dc new hello            # write hello.f3d
  f3dc run hello.f3d        # → build/hello.ppm  (+ .png if convert exists)
  f3dc                      # in a folder with one .f3d file: runs it
```

### 2.1 The five commands at a glance

| Command | Writes files? | Needs `gfortran`? | Default output | Exit-0 summary (stdout, one line) |
|---|---|---|---|---|
| `new <name>` | The one `.f3d` file only | No | `./<name>.f3d` (or `<dir>/<name>.f3d`, §3.2) | `✓ created hello.f3d — next: f3dc run hello.f3d` |
| `check <file>` | **Never** | No | — | `✓ hello.f3d: ok (1 object, 12 triangles)` |
| `build <file>` | Yes, under `--out` (default `build/`) | No (emits `.f90`, does not compile it) | `build/<stem>.{f90,json,js,html}` | `✓ built hello → build/ (4 files)` |
| `run <file>` | Yes, under `build/` | **Yes** | `build/<stem>.ppm` (+ best-effort `.png`) | `✓ rendered build/hello.ppm in 0.8s — open build/hello.html to view in a browser` |
| `fmt <file>` | In place (atomic), unless `--check`/`--diff` | No | — | `✓ hello.f3d already formatted` / `✓ formatted hello.f3d` |

Notes on deliberate omissions:

- **No `clean` in v1.** `build/` is one directory; the help text says
  `rm -rf build`. Adding `clean` is a v1.1 candidate if users ask — not before.
- **No `serve` / dev server.** `run` emits a self-contained HTML viewer
  (P04 §6.4); opening a file must stay the whole story.
- **No `init` / project command.** A project *is* a folder with `.f3d`
  files in it. `new` creates one file, not a directory tree (§3.2).

### 2.2 Argument grammar (normative)

```
f3dc [--version] [--help]
f3dc [global-flags] <command> [command-flags] [file] [global-flags]
f3dc [global-flags] <file.f3d|.json|.obj> [run-flags]      # shorthand for run
```

- Global flags are accepted **before or after** the subcommand (users do
  both; `argparse` subparsers alone punish the second form — the driver
  pre-scans and hoists known globals).
- Exactly one input file per invocation in v1. Multiple files →
  exit 2 with `hint: run f3dc once per file, e.g.  for f in *.f3d; do f3dc check "$f"; done`.
  (Batch/glob support is a v2 question; a clear refusal beats a half-feature.)
- `-` as the file means **stdin** for `check` and `fmt` only; diagnostics
  then name the file `<stdin>`. `run`/`build` reject `-` (they must name
  outputs) with exit 2 and the reason.
- Input type is by extension: `.f3d`, plus legacy `.json` (scene.json v1/v2)
  and `.obj` via the P04 compat reader. Unknown extension → exit 2,
  did-you-mean on the filename if a similarly-named `.f3d` exists (P08 §4).
- Unknown command → exit 2 + did-you-mean (`f3dc buld` → `did you mean 'build'?`)
  using the same suggestion machinery as P08 keywords. Unknown flag likewise,
  plus the one-line usage for that command — never a full help dump to stderr.

---

## 3. Command specifications

### 3.1 Bare and shorthand invocation (the "one command" promise)

Resolution order for `f3dc` with no arguments:

1. If the current directory contains `scene.f3d` or `main.f3d`, run that one.
2. Else if it contains **exactly one** `*.f3d`, run it.
3. Else if it contains **zero**, print the short help to stdout plus, on
   stderr, `no .f3d file here — create one:  f3dc new hello` and exit 2.
4. Else (several, none preferred), list the candidates and exit 2:
   `found 3 scenes here — pick one:  f3dc run a.f3d | b.f3d | c.f3d`.
   Guessing among several is the one unforgivable surprise.

`f3dc <file>` ≡ `f3dc run <file>` in all flags, output, and exit codes.
This shorthand is documented in `--help`, not a hidden trick.

### 3.2 `f3dc new <name> [--template cube|empty] [--force]`

- `<name>` may be `hello`, `hello.f3d`, or `scenes/hello`: the extension is
  added iff absent; a path creates parent dirs. The result is **one file** —
  no directory, no README, no config, no `.gitignore` edits.
- Default template is the P03 3-line contract, commented so it teaches:

  ```f3d
  # hello.f3d — created by f3dc new. Run it with:  f3dc run hello.f3d
  cube red
  spin it
  render
  ```

- `--template empty` writes a single comment line (for users who resent
  examples). No other templates in v1.
- Refuses to overwrite an existing file (exit 3, §7) unless `--force`;
  the refusal prints the first line of the existing file so the user can
  tell whether it is theirs. Never truncates before the check.
- Success summary names the *next* command with the actual filename filled in.

### 3.3 `f3dc check <file> [--strict] [--format text|json]`

- Runs P04 stages 1–3 (lex/parse/validate) only. **Writes nothing** — not
  even a cache. Safe in CI, safe on read-only mounts, safe to run on a file
  in the repo root (it will not touch the checked-in `scene.json`).
- Exit 0 prints counts (objects / triangles after desugaring) so "ok" is
  evidence, not vibes. Warnings print but do not fail unless `--strict`
  (then exit 1, footer says `failed only because --strict`).
- `--format json` = P08 §5.4 JSON-Lines diagnostics on stderr; the stdout
  summary becomes a single JSON object too, so `check` is fully machine-usable.

### 3.4 `f3dc build <file> [--target …] [--out dir] [--force] [--stats]`

- Full P04 pipeline, `--target all` by default: `<stem>.f90`, `<stem>.json`
  (v2 + legacy v1 as `<stem>.legacy.json` — final naming owned by P04 §6.2),
  `<stem>.js`, `<stem>.html`, all under `--out` (default `build/`).
- **Does not invoke `gfortran`.** `build` is the compiler; `run` is the
  compiler + toolchain + renderer. This split is what makes `build` usable
  on a machine without Fortran, and in CI stages.
- **Incremental:** each output carries the P04 header stamp
  (`generated by f3dc <ver> from <file> sha256:<…>`). If inputs, flags, and
  version are unchanged, `build` writes nothing and says
  `✓ hello: up to date (build/ unchanged)`. `--force` ignores the stamp.
- **Clobber rule (P04 §10, normative here):** an existing output is
  overwritten iff it carries an `f3dc` stamp or `--force` is given.
  Otherwise exit 3 naming the file. This is precisely what protects the
  repo-root `scene.json` / `viewer.html` if a user passes `--out .`.

### 3.5 `f3dc run <file> [--out dir] [--keep-build] [--open] [--watch]`

Pipeline: `build` (Fortran target only, into `build/`) → compile → execute →
report. Details that make or break the feel:

- **Compile line mirrors the `Makefile` exactly** (P04 §10):
  `gfortran -O3 -Wall -Wextra -fcheck=all -Jbuild/include src/math_3d.f90
  src/mesh.f90 src/camera.f90 src/renderer.f90 build/<stem>_scene.f90
  -o build/<stem>`, with engine sources located per §5.3. Flags are not
  user-tweakable in v1 except via `F3DC_FFLAGS` (§4.3) — one documented
  escape hatch, not five flags.
- **gfortran output is captured, never streamed raw.** On failure, `f3dc`
  prints (stderr) the generated file and line it can map, the first
  gfortran error block verbatim *below* its own plain-English header, and
  exit 4. A raw backtrace as the *only* output is a P20 bug (cf. P08 §1.2).
  This almost always indicates an `f3dc` codegen bug, so the message says so
  and asks for the generated `.f90` in a bug report — it does not blame the user.
- **Runtime output is captured likewise.** The Fortran program's own prints
  appear only with `-v`. On a non-zero runtime exit, stderr shows the last
  ≤ 20 lines and exit 4; partial outputs are left in place and named as partial.
- **PNG is best-effort, labelled as such.** If ImageMagick `convert` exists
  (as in today's `make run`), `run` also writes `<stem>.png` and the summary
  mentions it; if not, the summary says
  `… (no PNG: 'convert' not found — the .ppm is the full-quality image)`.
  Never a silent difference between machines (today's `|| true` is the
  anti-pattern this replaces).
- **`--open`** (v1.1, optional): after a successful run, open the `.html`
  viewer with the platform opener (`xdg-open` etc.). Off by default —
  a CLI that pops windows unasked in CI/SSH is hostile. Detected-SSH /
  no-`DISPLAY` → prints the path instead, exit unchanged.
- **`--watch`** is **out of v1**: listed in help as `not yet available`
  only if trivially cheap; otherwise not mentioned. No vapourware flags —
  a flag that errors "not implemented" is worse than no flag.
- Timing in the summary is wall-clock for the whole run, one decimal place,
  seconds; stage timings (`lex/parse/compile/render`) only with `-v`.

### 3.6 `f3dc fmt <file> [--check] [--diff]`

- Canonical re-print per P04 §10: 2-space indent, sorted properties,
  one statement per line, comments preserved and re-attached to the
  statement that followed them, exactly one trailing newline, LF endings.
- **Idempotent by construction and by test:** `fmt(fmt(x)) == fmt(x)` is a
  golden property (§11); a non-idempotent formatter is a release blocker.
- Default mode rewrites **in place, atomically** (temp + rename, original
  permissions preserved), and only if the content actually changes;
  an unchanged file keeps its mtime and the summary says `already formatted`.
- `--check`: writes nothing; exit 0 if formatted, **exit 1** if not, with
  stderr `hello.f3d is not formatted — run:  f3dc fmt hello.f3d`.
  This is the CI spelling; §7 explains why 1 is correct here.
- `--diff`: writes nothing; unified diff to **stdout** (it is the requested
  data), header/footer chatter suppressed. Combinable with `--check`.
- `fmt` on a file with scene errors: exit 1 with the P08 diagnostics and
  **no write** — a formatter must never "fix" a file it cannot fully parse
  into a different file it only half understands.
- `fmt -` reads stdin, writes the formatted result to stdout (editor glue).

---

## 4. Zero-config defaults

### 4.1 The defaults table (every value traceable to `src/main.f90`)

| Setting | Default | Source today | Flag / config key |
|---|---|---|---|
| Image size | 640 × 480 | `main.f90` `width/height` | scene statement; `--size WxH` (run/build override) |
| Camera | pos `(3, 2.5, 4)`, target `(0,0,0)`, fov 60, near 0.1, far 100 | `camera_init` call | scene statement (P03) |
| Light | directional `(-0.5, -1, -0.7)`, Lambertian | `main.f90` | scene statement |
| Default object pose | cube size 2, rotate 20° X / 35° Y | `create_cube(cube, 2.0)`, model matrix | scene statement |
| Background | `(25, 25, 35)` | `renderer.f90` framebuffer clear | scene statement |
| Output dir | `build/` (created on demand) | — (today: repo root) | `--out` |
| Output stem | input filename stem | — (today: fixed `output_render`) | derived, not settable in v1 |
| Targets (build) | `all` (fortran, json, js, html) | P04 §6 | `--target a,b` |
| JSON dialect | `both` (v2 + legacy v1) | P04 §10 | `--json-dialect` |
| Optimization | on (P04 O1–O7) | P04 §4.4 | `--no-optimize` |
| Diagnostics format | `text` | P08 §5 | `--format text|json` |
| Colour | `auto` (TTY + no `NO_COLOR`) | P08 §5.2 | `--color auto|always|never` |
| Verbosity | normal (summary only) | — | `-q` / `-v` (repeatable: `-vv` = stage timings + subprocess commands) |

Rule: **a flag may override a default; a flag may never be required to
repair a default.** If a zero-flag run of a valid scene produces a bad
picture, the bug is in the default, not the user.

### 4.2 Discovery (no manifest, no registration)

- Scenes: by filename in the current directory only (§3.1). No recursion,
  no index file, no "project root" concept in v1.
- Engine sources (for `run`): §5.3's search order. The user never types a path.
- Templates for `new`: embedded in the script (§5.2). No template directory
  to lose, no `--template-dir` in v1.

### 4.3 Optional configuration — precedence and the full list

Precedence, highest first (each layer overrides only keys it sets):

```
command-line flag  >  environment variable  >  ./f3d.toml  >  ~/.config/f3dc/config.toml  >  built-in default (§4.1)
```

- `f3d.toml` is **optional and tiny by design** — v1 recognises exactly:
  `out`, `target`, `color`, `fflags`, `open` (bool). Unknown keys are a
  *warning* with did-you-mean, never silently ignored (silent ignore is how
  config files become haunted). A malformed file is exit 3 with a P08-style
  diagnostic pointing at the line — not a Python traceback.
- Environment: `F3DC_OUT`, `F3DC_TARGET`, `F3DC_FFLAGS`, `F3D_HOME` (§5.3),
  plus the cross-tool standards `NO_COLOR` and `CI` (`CI` ⇒ `--color=never`,
  no progress, no `--open`).
- Config is **never created implicitly.** `new` does not write one; `run`
  does not write one. If a user never learns config exists, nothing is lost.

---

## 5. Packaging & installation

### 5.1 Decision: single-file script for users, package for developers

P04 §9 lays the compiler out as a package (`tools/f3dc/f3dc_pkg/…`) with a
shim — right for development, wrong as the thing a user downloads (a folder
is not an install). P20 resolves the tension:

| Artifact | Audience | Form |
|---|---|---|
| `tools/f3dc/f3dc_pkg/` + shim (P04 §9) | Contributors | Source tree, run in place: `tools/f3dc/f3dc …` or `make f3dc` |
| **`f3dc`** (release artifact) | **Users** | **One self-contained `#!/usr/bin/env python3` file**, stdlib only, all modules + templates inlined by a build step (`tools/f3dc/make_single_file.py`, stdlib `zipapp` is the fallback if inlining gets unwieldy) |
| Engine payload | Users (for `run`) | `src/*.f90` + viewer template, installed beside the script under a share dir (§5.3) — the Fortran runtime cannot be embedded in a Python file honestly |

Rules that keep the two forms one product:

- The single file is **generated, never hand-edited**; its header carries
  the version and the git sha of the package it was built from.
- CI runs the full golden suite **against the generated single file**, not
  only the package — the artifact users get is the artifact tested.
- Version identity: `f3dc --version` prints the same string from both forms;
  a mismatch in any bug report is itself diagnostic.
- **No PyPI, no pip, no npm in v1.** A pip package may come later as a
  *mirror* of the same artifact; the canonical install must work with
  nothing but `python3`, a POSIX shell, and (for `run`) `gfortran`.

### 5.2 What the single file contains / does not contain

Contains: lexer, parser, validator, optimizer, all emitters, CLI, `new`
templates, the HTML viewer template (as a string constant), diagnostics
catalogue text for `--explain` (P08 §6.3). Does **not** contain: Fortran
sources (found per §5.3), tests, or any network code — `f3dc` must be
auditable as "this file never opens a socket", and a test greps for
`socket`/`urllib` imports to keep it true.

### 5.3 Engine discovery (`run` needs `src/*.f90`)

Search order, first hit wins, reported by `f3dc doctor` and `-vv`:

1. `$F3D_HOME/src/` (explicit override, for developers and odd layouts)
2. `./src/` — running inside a repo checkout just works, zero install of data
3. `<script's dir>/../share/f3dc/src/` — the `make install` layout (§5.4)
4. `~/.local/share/f3dc/src/` — the copy-script layout (§5.4, method B)

If none is found, `check`/`build`/`fmt`/`new` **still work** (they never
needed Fortran); only `run` fails, with exit 3 and:
`error: cannot find the Fortran engine sources — run 'f3dc doctor' for
fixes, or set F3D_HOME=<repo>`. Degrading to 4-of-5 commands beats refusing
to start.

### 5.4 Install methods (exactly three, documented in this order)

**A. From a checkout (contributors, and v1's primary path):**

```console
$ make install            # PREFIX defaults to ~/.local — no sudo, ever, by default
$ make install PREFIX=/usr/local   # only if the user asks for it, in writing, in the docs
$ make uninstall          # removes exactly what install wrote (manifest file)
```

`make install` copies: `f3dc` (generated single file) → `$(PREFIX)/bin/`
(mode 755), `src/*.f90` + viewer template → `$(PREFIX)/share/f3dc/`, and
writes `$(PREFIX)/share/f3dc/install-manifest.txt` so `uninstall` is exact,
not glob-and-pray. It ends by running `f3dc doctor` (§6.3) and printing its
verdict — an install that does not self-check is a hope, not an install.
Existing unrelated `make` targets (`all`, `run`, `clean`) are untouched;
`install`/`uninstall`/`f3dc` (build the single file) are additive.

**B. Download-and-copy (no checkout):** one file from the release page:

```console
$ curl -LO <release-url>/f3dc        # URL owned by the release plan; never a pipe-to-shell
$ chmod +x f3dc && ./f3dc doctor     # doctor explains the engine-payload step for `run`
```

**Explicitly forbidden in docs and README:** `curl … | sh`, `sudo pip
install`, and any instruction requiring admin rights for a per-user install.
If a step needs the network, it is a download the user can inspect — full stop.

**C. No install (try it in 10 seconds):** in a checkout, `tools/f3dc/f3dc
run hello.f3d` or `make run`-equivalent works in place; `--help` says so.
Trying must never require installing.

### 5.5 PATH and first-run UX

- If `~/.local/bin` is not on `PATH`, `make install` detects it and prints
  the exact one line for the user's shell (`export PATH="$HOME/.local/bin:$PATH"`
  for bash/zsh; fish spelling for fish), labelled as a suggestion to paste
  into their shell rc — **the installer never edits rc files itself.**
- Name-collision check: if a *different* `f3dc` already exists on `PATH`,
  install warns and `doctor` reports both paths. (The name is short; the
  check is cheap; the confusion is not.)
- Upgrades = re-run the same install; the manifest makes it idempotent.
  Downgrades likewise. No self-updater, no version check phone-home, ever.

---

## 6. Shell UX

### 6.1 Help system

- `f3dc --help`, `f3dc -h`, `f3dc help`, and bare `f3dc` in an empty folder
  all reach help; `f3dc <command> --help` is per-command and ≤ ~30 lines:
  one-line purpose, usage, flags with defaults *stated* (`--out DIR
  (default: build/)`), and **one runnable example**.
- Help goes to **stdout** and exits 0 when asked for; usage-after-error goes
  to stderr (one line + `try: f3dc <command> --help`) and exits 2.
- `--version` prints exactly `f3dc 0.1.0` on stdout (script-parseable);
  `-v --version` adds python/gfortran/engine-path lines on stderr.

### 6.2 Output discipline

| Stream | Contents |
|---|---|
| stdout | The requested data (rendered-file summary, `fmt --diff` output, `--emit` dumps, help, version) and the one-line success summary per command |
| stderr | Diagnostics (P08 format), progress, warnings, hints, subprocess output (only `-v` or on failure) |

- **Progress:** long stages (`run`'s compile/render) show a single updating
  line on a TTY (`rendering… 0.8s`), nothing when piped, and a plain
  `rendering hello…` line under `-v`. No spinner characters in piped output,
  no ANSI escapes when `NO_COLOR`/`CI`/not-a-TTY (P08 §5.2–5.3).
- **Symbols:** `✓` / `✗` mirror P08's footer convention, always paired with
  the words `ok`/`error` in plain mode so meaning never rides on a glyph or
  a colour alone. In `LC_ALL=C` / non-UTF-8 locales, fall back to `ok:` /
  `error:` prefixes — detected, not assumed.
- **Next-step hints:** success summaries end with the single most likely
  next action (§2.1). Failure summaries end with the fixing command.
  Exactly one hint, not a menu.
- **Timing:** summaries include elapsed time for `run`/`build` only;
  `check`/`fmt` are fast enough that a time would be noise (print it under `-v`).

### 6.3 `f3dc doctor` (the troubleshooting command)

Not one of the five, but the load-bearing meta-command every error message
points at. Checks, in order, each `ok` / `MISSING` + fix line:

```
f3dc 0.1.0
python3   ok        3.12.3 (>= 3.10 required)
gfortran  ok        GNU Fortran 13.2.0        [needed only for: run]
engine    ok        ~/.local/share/f3dc/src (4 modules + main template)
convert   optional  not found — run will write .ppm only   [not a failure]
PATH      ok        f3dc resolves to ~/.local/bin/f3dc
```

Exit 0 iff everything *required for at least `check`* is present; missing
`gfortran` is a **warning** (exit 0, clearly labelled) because 4 of 5
commands don't need it; missing python is impossible (the script is running);
missing engine payload fails only the `run` line. Fixes are copy-pasteable
and distro-neutral where possible (`install gfortran with your package
manager, e.g. apt install gfortran / brew install gcc`).

### 6.4 Completion and editor glue (v1.1, cheap, specified now)

- `f3dc --print-completion bash|zsh|fish` (hidden flag, generated from the
  same argparse spec so it cannot drift) prints a completion script to
  stdout; docs show the one-line redirect per shell. Completes: subcommands,
  flags, and `*.f3d` files for the file argument.
- No daemon, no shell hooks, nothing sourced at startup beyond the
  completion file the user chose to install.

---

## 7. Exit codes (normative — reconciles P04 §7 and P08 §7)

P04 proposed `0/1/2/3/4` (4 = gfortran stage); P08 proposed `0/1/2/3/70`
(70 = internal). P20 adopts the union; this table is the one `--help`,
the README, and the tests all quote:

| Exit | Meaning | Emitted by | Example |
|---|---|---|---|
| **0** | Success (warnings allowed, counted in the footer) | all | rendered; checked ok; already formatted |
| **1** | The *scene* is wrong, or a check-style test failed | `check`, `build`, `run`, `fmt` | any P08 `Exxxx` diagnostic; `--strict` warnings; `fmt --check` found unformatted input; `fmt` on an unparseable file |
| **2** | The *invocation* is wrong (usage) | all | unknown command/flag, wrong arg count, multiple input files, ambiguous bare invocation (§3.1 case 4), no scene found (case 3) |
| **3** | IO / environment failure | all | input not found/unreadable (P08 E5xx), output not writable, clobber refusal, `new` target exists, engine sources not found, malformed `f3d.toml` |
| **4** | Toolchain / runtime failure *after* a valid scene | `run` (and `build` never) | `gfortran` missing or failed on generated code; rendered program exited non-zero; renderer produced no output file |
| **70** | Internal `f3dc` error (E9000) | all | a traceback would have happened: instead, E9000 text + `please report: f3dc --version and the file` + the generated artifacts preserved |
| **130** | Interrupted by SIGINT | all | partial outputs named as partial; temp files cleaned |

Rules:

- **Scripts can branch on the table alone:** `1` = fix the scene,
  `2` = fix the command line, `3` = fix the filesystem/environment,
  `4` = fix the toolchain (or report a codegen bug), `70` = report a bug in `f3dc`.
- A rendered program's own non-zero status is **mapped to 4**, never passed
  through raw (a Fortran `STOP 1` must not masquerade as a scene error);
  the original status is quoted in the stderr message.
- `fmt --check` returning 1 is consistent, not a special case: 1 means
  "the input failed the check this command performs" (scene validity for
  `check`, canonical form for `fmt --check`).
- Signal deaths of children other than SIGINT → 4, with the signal named.
- **No other exit values may ever be produced.** An unhandled Python
  exception path that leaks exit 1 with a traceback is a release-blocking
  bug; the top-level handler converts it to 70 + E9000 (traceback only
  under `-vv` or `F3DC_DEBUG=1`).

---

## 8. Worked terminal sessions (normative transcripts)

These are the golden-path scripts the transcript tests (§11) replay.
Ellipses are *not* used inside command output; timings vary and are the
only non-asserted token.

### 8.1 Install and self-check

```console
$ git clone <repo-url> fortran-3d-engine && cd fortran-3d-engine
$ make install
installed f3dc 0.1.0 → ~/.local/bin/f3dc
installed engine → ~/.local/share/f3dc/
f3dc 0.1.0
python3   ok        3.12.3 (>= 3.10 required)
gfortran  ok        GNU Fortran 13.2.0
engine    ok        ~/.local/share/f3dc/src (4 modules + main template)
convert   optional  not found — run will write .ppm only
PATH      ok        f3dc resolves to ~/.local/bin/f3dc
✓ install complete — try:  f3dc new hello && f3dc run hello.f3d
```

### 8.2 The golden path: `new` → `run` (two commands, first image)

```console
$ mkdir ~/first-scene && cd ~/first-scene
$ f3dc new hello
✓ created hello.f3d — next: f3dc run hello.f3d
$ cat hello.f3d
# hello.f3d — created by f3dc new. Run it with:  f3dc run hello.f3d
cube red
spin it
render
$ f3dc run hello.f3d
✓ rendered build/hello.ppm in 1.2s — open build/hello.html to view in a browser
$ ls build/
hello  hello.f90  hello.html  hello.js  hello.json  hello.legacy.json  hello.ppm
```

(The user edits `red` → `blue`, re-runs, and has a feedback loop. That loop,
not any feature list, is the product.)

### 8.3 The one-command promise: bare `f3dc`

```console
$ cd ~/first-scene
$ f3dc
✓ rendered build/hello.ppm in 0.4s — open build/hello.html to view in a browser
$ f3dc hello.f3d        # shorthand — identical result
✓ rendered build/hello.ppm in 0.4s — open build/hello.html to view in a browser
```

(Second run is faster: unchanged Fortran objects are not recompiled —
`run` reuses `build/` stamps exactly as `build` does, §3.4.)

### 8.4 `check`: failure, fix, pass (diagnostics per P08)

```console
$ f3dc check hello.f3d
error[E2001]: unknown word 'cub'
  --> hello.f3d:2:1
   |
 2 | cub red
   | ^^^
   = help: did you mean 'cube'? Change line 2 to:  cube red
✗ not checked: 1 error in hello.f3d — fix E2001 first (line 2).
$ echo $?
1
$ sed -i 's/^cub /cube /' hello.f3d
$ f3dc check hello.f3d
✓ hello.f3d: ok (1 object, 12 triangles)
```

### 8.5 `fmt` and `fmt --check` in CI

```console
$ f3dc fmt messy.f3d
✓ formatted messy.f3d
$ f3dc fmt messy.f3d
✓ messy.f3d already formatted
$ f3dc fmt --check messy.f3d; echo "ci-exit=$?"
✓ messy.f3d is formatted
ci-exit=0
$ printf 'cube   red\n' > messy.f3d
$ f3dc fmt --check messy.f3d; echo "ci-exit=$?"
messy.f3d is not formatted — run:  f3dc fmt messy.f3d
ci-exit=1
```

### 8.6 `build` without Fortran (web artifacts only)

```console
$ f3dc build hello.f3d --target json,html --out dist/
✓ built hello → dist/ (2 files)
$ f3dc build hello.f3d
✓ built hello → build/ (4 files)
$ f3dc build hello.f3d
✓ hello: up to date (build/ unchanged)
```

### 8.7 Missing `gfortran`: degrade, don't die

```console
$ f3dc run hello.f3d
error: 'run' needs gfortran, which was not found on PATH.
  check/build/fmt still work. Fixes:
    Debian/Ubuntu:  sudo apt install gfortran
    macOS:          brew install gcc
  then verify with:  f3dc doctor
$ echo $?
4
$ f3dc check hello.f3d
✓ hello.f3d: ok (1 object, 12 triangles)
```

### 8.8 Clobber protection in the repo root

```console
$ cd ~/fortran-3d-engine        # the checkout, with its checked-in scene.json
$ f3dc build demo.f3d --out .
error: refusing to overwrite scene.json — it was not generated by f3dc.
  use --out build/ (the default), or pass --force if you really mean it.
$ echo $?
3
```

---

## 9. Safety, determinism, and non-surprises (CLI-level)

- **Atomic writes everywhere** (temp file in the target dir + rename);
  a killed `fmt`/`build` leaves either the old file or the new one, never a half.
- **Deterministic outputs:** same input + same `f3dc` version ⇒ byte-identical
  outputs (P04 §11.5); the CLI adds no timestamps or absolute paths *inside*
  generated files (the stamp carries the source sha, not the clock).
- **No network, no telemetry, no auto-update check** — stated in `--help`
  and enforced by the import grep test (§5.2).
- **No destructive defaults:** the only in-place writer is `fmt`, the only
  overwrites are stamped-or-forced (§3.4), the only directory ever created
  implicitly is `--out`. `new` never overwrites (§3.2).
- **Locale/encoding:** input read as UTF-8 with a P08 diagnostic (not a
  traceback) for invalid bytes; filenames with spaces work everywhere
  (subprocess calls are argv lists, never shell strings — tested with
  `"my scene.f3d"`).

---

## 10. Relationship to sibling plans

| Plan | Owns | P20 takes from it / gives back |
|---|---|---|
| P03 (grammar) | `.f3d` syntax, defaults, 3-line contract | P20's `new` template *is* P03's contract example; defaults table §4.1 mirrors P03's desugaring |
| P04 (pipeline) | Stages, emitters, package layout, first CLI sketch (§10) | P20 supersedes P04 §10 where they differ (bare invocation, `doctor`, install, transcript norms); P04's flags/targets/clobber rule are adopted unchanged |
| P08 (error UX) | Diagnostic format, codes, colour/TTY policy | P20 adopts P08's format wholesale; §7 merges P08 §7 with P04 §7 exit codes — **if P08 is edited, §7 here must be re-checked** |
| P05 (Fortran gaps) | What the runtime can/can't do | `run`'s captured-output and exit-mapping rules (§3.5) are where P05 limits surface to users |
| Release/README work (future) | Release page, download URL | P20 specifies the artifact and install commands the README must quote verbatim (§5.4) |

Explicit non-goals for P20: language features, new render targets, a GUI,
a package-manager submission (PyPI/Homebrew/apt), Windows support beyond
"the Python file runs under `py` if `gfortran` exists" (no installer, no
transcripts promised), and localisation (P08 §0 keeps it possible; P20
ships English only).

---

## 11. Testing & acceptance

1. **Transcript tests (the core of P20).** §8.1–§8.8 are replayed by a
   harness (`tools/f3dc/tests/test_transcripts.py`, stdlib only) in a temp
   HOME + temp cwd: run the commands, assert stdout/stderr (timings masked),
   exit codes, and the resulting file tree. A transcript that drifts fails CI —
   the documentation *is* the test.
2. **Clean-room install test.** Fresh container/VM, no repo on `PATH`:
   `make install` → `f3dc doctor` exit 0 → §8.2 verbatim → a `.ppm` exists
   and decodes as P3 with the expected dimensions. Also the uninstall leg:
   after `make uninstall`, the manifest paths are gone and nothing else is.
3. **Single-file parity.** The golden suite (P04 §11) runs twice: package
   form and generated single file; any output difference fails.
4. **Help-example tests.** Every `EXAMPLES` line in every `--help` is
   extracted and executed in a sandbox; a failing example fails the build.
5. **Exit-code matrix.** One fixture per row of §7 per applicable command,
   asserting the exact code — including the ugly ones (SIGINT → 130,
   gfortran failure → 4, traceback-injection fault test → 70 with no
   traceback on stderr at default verbosity).
6. **Hostile-environment tests.** `NO_COLOR=1`, piped stdout, `CI=1`,
   read-only cwd (for `check`), filename with spaces, missing `gfortran`
   (PATH scrubbed), missing engine payload, pre-existing foreign `f3dc` on PATH.
7. **Idempotence & no-clobber tests.** `fmt` twice (§3.6); `build` twice
   (second is a no-op, mtimes unchanged); §8.8's refusal; `new` over an
   existing file.
8. **Human acceptance (once per release).** A person who has never seen the
   project, given only the README's install section, reaches a rendered
   image unaided within the §0.1 budget. Observed, timed, notes filed —
   this test cannot be automated away.

---

## 12. Phased delivery

| Phase | Deliverable | Usable result | Depends on |
|---|---|---|---|
| P20-a | CLI skeleton: argparse layout, global-flag hoisting, `--help`/`--version`, exit-code plumbing + top-level 70-handler, bare/shorthand resolution (§3.1) | `f3dc check` (from P04-a) feels finished from day one | P04-a |
| P20-b | `new` + templates, `check` summaries, `fmt` + `--check`/`--diff` | Write-and-validate loop with no Fortran present | P04-a/b |
| P20-c | `build` (stamps, incremental, clobber rule), `run` (captured gfortran/runtime, PNG labelling, timing) | The §8.2/§8.3 golden path end-to-end | P04-c/e |
| P20-d | `doctor`, single-file generator + CI parity, `make install`/`uninstall`, PATH hint | §8.1 install transcript passes clean-room | P20-c |
| P20-e | Transcript/help-example/exit-matrix suites in CI; completion scripts (§6.4); `--open` | P20 acceptance (§11) fully enforced | P20-d |

Each phase ships with its transcripts updated in §8 — a phase that changes
user-visible output without updating §8 is incomplete by definition.

## 13. Risks & open questions

1. **Single-file drift** is the standing risk of §5.1; mitigated by
   generation + parity tests, but if the package outgrows comfortable
   inlining, the fallback is a stdlib `zipapp` (`.pyz`) — decided by file
   size/pain, not preemptively.
2. **Engine payload versioning:** script and `src/*.f90` can skew when a
   user copies a new `f3dc` over an old share dir. `doctor` should compare
   the payload's version stamp (a `VERSION` file installed beside `src/`)
   against the script's and warn on mismatch — specified as a `doctor`
   warning, implementation in P20-d.
3. **`convert` divergence:** PNG availability differs per machine (§3.5).
   If users start *depending* on PNG, the honest fix is a tiny stdlib PPM→PNG
   writer or a Fortran-side PNG path — a future plan, not a P20 flag.
4. **Name collision** with unrelated `f3dc` binaries (§5.5): detection is
   specified; renaming is not on the table unless a real collision appears.
5. **Open:** should `run` also print a `file://` URL for the HTML viewer?
   Helpful in some terminals, noise in others — decide from the §11.8
   human test, not by taste.
6. **Open:** multi-file/batch mode (§2.2) and `--watch` — both deliberately
   deferred; both must enter through user requests, not symmetry with other tools.
