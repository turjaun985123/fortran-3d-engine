# Security

Forge3D is a small open-source project. This document states its
security posture as implemented in the code. It is not a guarantee:
treat every input file as untrusted (see "Untrusted input" below).

## Preview server: loopback by default

`f3dc preview` is a local development server. Its transport is
`compiler/preview_http.c`, driven by `compiler/src/f3dc_preview.f90`,
which passes the literal host `127.0.0.1`.

The bind policy in `preview_http_open` / `resolve_bind_addr` is
loopback-only and never falls back to `INADDR_ANY`:

- A null or empty host binds `127.0.0.1`.
- A literal IPv4 address in `127.0.0.0/8` binds that address.
- Any other literal IPv4 address — including `0.0.0.0` — is refused
  (`EADDRNOTAVAIL`).
- A hostname (for example `localhost`) is resolved with
  `getaddrinfo()`; the first result in `127.0.0.0/8` is bound. If it
  resolves to no loopback address, or does not resolve at all, the
  open is refused. The bind is never silently widened to all
  interfaces.
- Binding a non-loopback address requires an explicit opt-in in the
  host string itself: the `ext:` prefix, for example `ext:0.0.0.0`
  or `ext:192.168.1.10`. Only use it on a network you trust, and
  note that anyone who can reach that address can then reach the
  preview.

Per connection, the server reads one request head (request line and
headers, up to 64 KiB) into a buffer on that connection's stack.
There is no shared static request state, so bytes from an earlier,
longer request cannot be seen by a later one. One request is served
per connection (`Connection: close`).

## Compiler resource limits

The `.f3d` front end (`compiler/src/f3dc_lexer.f90` and
`compiler/src/f3dc_parser.f90`) caps untrusted source before it can
exhaust memory, overflow arithmetic, or hang the compiler. Every
limit below is reported as an `E820` diagnostic — a positioned
error, not a crash:

| Limit | Value |
|---|---|
| Input size (`MAX_INPUT_BYTES`, lexer) | 1 MiB |
| Line length (`MAX_LINE_CHARS`, lexer) | 4,096 characters |
| Tokens per file (`MAX_TOKENS`, lexer) | 262,144 |
| Internal tokens (`MAX_ITOKS`, parser) | 262,144 |
| Grouped lines (`MAX_LINES`, parser) | 65,536 |
| Errors per parse (`MAX_ERRS`, parser) | 1,024 |
| `repeat` / `ring` count (`MAX_REPEAT_COUNT`, parser) | 1,000,000 |
| `grid` size (`MAX_GRID_CELLS`, parser) | 1,000,000 rows/cols and cells |

The `repeat`/`grid` guards bound each factor before multiplying, so
`rows * cols` cannot wrap `int64` and downstream per-instance
expansion cannot explode. Token/list growth is likewise capped
before doubling, so the growth arithmetic cannot overflow, and
growth allocations are checked.

## Engine resource limits

The engine (`src/main.f90`) guards a render with two environment
variables. Both must be positive integers; an unparsable or
non-positive value is an error (exit 2), as is exceeding the limit:

| Variable | Default | Meaning |
|---|---|---|
| `FORGE3D_MAX_FRAMES` | 100,000 | Maximum frames in one render |
| `FORGE3D_MAX_RESOLUTION` | 268,435,456 | Maximum `width * height` in pixels (16,384 × 16,384) |

Textures (`src/texture.f90`): `tex_dims_ok` is enforced before any
pixel storage is allocated — in the PPM loader, the PNG decoder,
and defensively on conversion — so a hostile header (for example a
PNG claiming 100,000 × 100,000) fails cleanly instead of attempting
the allocation. The caps are 16,384 per axis (`TEX_MAX_DIM`) and
2^28 = 268,435,456 pixels in total (`TEX_MAX_PIXELS`), with the
pixel count formed in `int64` so the check itself cannot overflow.

JSON (`src/json_reader.f90`, the shared parser behind scene and
glTF loading): at most 4,000,000 nodes per document
(`JSON_MAX_NODES`) and at most 268,435,456 bytes (256 MiB) of input
(`JSON_MAX_INPUT`). Exceeding either is a clean parse error
(`ok = .false.` with a byte offset), never an unbounded allocation.

## Untrusted input

`.f3d`, `.scene`, `.obj`, `.gltf`, and `.png` files are all parsed
by code that assumes the input may be hostile, truncated, or
corrupt. The expected behaviour on any input — valid, invalid,
truncated, or absurd — is acceptance or a proper error: never a
crash, an out-of-bounds access, or a hang.

That code is covered by the fuzz harnesses in `tests/fuzz/`
(`fuzz_lexer`, `fuzz_parser`, `fuzz_loaders`, `fuzz_png`,
`fuzz_scene`), built with AddressSanitizer, UndefinedBehaviorSanitizer,
and gfortran `-fcheck=all`. Generation is deterministic, so a
finding reproduces from its seed (and case index, if printed).
See `tests/fuzz/README.md` for how to run them.

Per that README's policy, a fuzz finding is not closed by a fix
alone: the minimised failing input must first land as a regression
test in the owning layer's normal test suite, citing the seed it
came from.

## Reporting a vulnerability

Please do not open a public issue for a vulnerability that is not
yet fixed.

- Preferred: use GitHub's private vulnerability reporting for this
  repository (the "Report a vulnerability" form under the
  repository's Security tab), if it is enabled.
- If private reporting is not available, open a regular issue
  asking for a private contact channel, without including the
  details of the vulnerability in the issue itself.

A useful report includes:

- A description of the problem and the component involved
  (compiler, preview server, or engine loader/renderer).
- A minimal reproducer: the smallest input file or command line
  that triggers it, and what happens (crash, sanitizer report,
  hang, limit bypass).
- For a fuzz finding: the harness name, the seed, the case index
  if one was printed, and the iterations used — together these
  identify the exact input.
- The version or commit you tested, and your platform.

There is no bug bounty and no guaranteed response time; this is a
small project maintained on a best-effort basis. Fixes for fuzz
findings follow the policy above: a regression test lands with
the fix.
