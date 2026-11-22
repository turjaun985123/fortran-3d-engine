# P28 — Scope & Waves: v1 Is Milestone 1, Not the Ceiling

> **Status:** Planning only — no code changed by this document.
> **Supersedes:** Any earlier "v1 scope cut / Won't" framing for this repo,
> including cut-line language implied by P03 §11, P10 §0, P14 §0, and
> P15 §0 where those sections present a deferral as a product limit.
> Those plans' *technical* rulings stand; only their *scope status*
> changes: deferred means **scheduled in a later wave**, never dropped.
> **Repo state audited:** `src/*.f90` (5 files, ~629 LOC), `viewer.html`,
> `scene.json`, `Makefile`, `docs/plan/P01–P20` (2026-11-23). Plans
> P21–P27 were not present in the tree at audit time; §9 gives the rule
> that assigns them a wave when they land — they are not silently omitted.
> **Goal served:** **Full Three.js + PixiJS-3D feature parity — all
> features, better and easier.** v1 is the first shippable milestone on
> that road, not a smaller product pretending to be the destination.

---

## 0. Verdict in one page

| Question | Ruling |
|---|---|
| What is the product goal? | Parity with the combined Three.js + PixiJS-3D feature surface (P01/P02 censuses), delivered with the P01 §5 contract: ≤⅓ the authored lines, ≤5 new concepts per task, zero scaffold, no silent black screen. |
| What is v1? | **Milestone 1 only:** a beginner writes a short `.f3d` file, compiles it to JSON / HTML / Fortran, renders it natively, and views it interactively — end to end, tested, in CI. |
| Is there a Won't list? | **No.** This plan contains no Won't bucket. Every parity feature is in Must, Should, Wave 2, or Wave 3. The only things refused in §8 are *dishonest claims and silent fakes*, which are process invariants, not features. |
| What happens to a feature that misses its wave? | It moves **one wave later, in writing, in this file** — with its dependency reason intact. It never disappears, never becomes a silent no-op, and never renders approximately while claiming to be correct (P10 §2.2, P14 §1.2). |
| When can parity be claimed? | Only when the §7 parity ledger is fully checked against running code and acceptance tests. v1 must be described as "milestone 1 toward parity", never as parity itself. The same honesty rule gates every performance claim (§8). |

**Wave definitions:**

- **Must (v1):** v1 does not ship without it. Removing one breaks the
  one-sentence promise in §1.
- **Should (v1, slip-allowed):** Planned for v1, strengthens the promise,
  but may slip to Wave 2 by the §6 slip rule without unshipping v1.
- **Wave 2:** Complete *common authoring* parity — the features a normal
  Three.js/PixiJS user reaches for weekly: textures, real shadows,
  glTF, full keyframes, spotlights, smooth shading from imported normals.
- **Wave 3:** Complete *advanced / ecosystem* parity — PBR and image-based
  lighting, post-processing, skeletal/morph animation, particles,
  custom shaders, WebGL2 path, sprites/text geometry, XR and the long
  tail of loaders/controls. Each Wave 3 item needs its own plan before
  build (§9); being Wave 3 is a sequencing decision, not a dismissal.

---

## 1. The v1 promise (the only sentence v1 marketing may use)

> Write a scene in a few lines of `.f3d`, run one command, get a correct
> still image natively and an interactive page in the browser — with an
> error message that teaches you how to fix it when you get it wrong.

Ground truth that makes this a milestone, not a rewrite: today
`src/main.f90` hard-codes one cube (640×480, one directional light,
`output_render.ppm` + `scene.json` + `model.obj` exports), the renderer
already does barycentric rasterisation with a Z-buffer and per-face
Lambert shading, and `viewer.html` already displays the exported
triangles. v1 connects those pieces through a compiler; it does not
replace them.

**Non-negotiable invariants in every wave** (inherited, not re-decided):

1. **3-line contract (P03 §1, P01 R1/R5):** the rotating cube stays
   3 lines, unchanged, forever. New features are additive syntax.
2. **No silent no-ops (P08, P10 §2.2, P14 §8):** an unimplemented or
   not-yet-wave keyword is parsed and rejected with a named diagnostic
   stating its wave — never accepted and ignored, never faked.
3. **Legacy golden (P10 §9, P18 §6):** a scene with no new features
   renders pixel-identically to today's `output_render.ppm`.
4. **One-place features (P01 R4):** a feature needing flags in ≥2 places
   is a DSL design failure, in whichever wave it lands.

---

## 2. MUST — v1 does not ship without these

| # | Item | Owner plan(s) | Why it is Must (removing it breaks §1) |
|---|---|---|---|
| M1 | **DSL core:** lexer/parser/validator for the P03 grammar — scene, camera, one directional light, objects with `at`/`rotate`/`scale`/colour, named objects + `it`/`last`, defaults table as single source of truth | P03, P04 §§4.1–4.3 | There is no product without the language. Defaults are the ease claim: lit, framed, and coloured without being asked. |
| M2 | **Diagnostic UX for the core:** spans, did-you-mean, error codes + `--explain`, documented exit codes, "not supported yet — Wave N" errors for every reserved keyword | P08, P04 §7, P20 §7 | P01 pain #3 is black-screen silence. A compiler whose errors don't teach is just Three.js's failure mode with fewer features. |
| M3 | **Primitives:** cube (exists: `create_cube`) + sphere, cylinder, plane, pyramid, cone, torus, with P11 defaults, segment/`detail` rules, normals and winding verified per primitive | P11, P05 | One cube is a demo, not a compiler. P11 §1: defaults are the contract — each primitive is one word in the DSL. |
| M4 | **Compiler pipeline:** `parse → validate → optimise → emit` with frozen IR (`ir_version: 1`); the safe optimisation subset only (constant folding, transform baking, dead-object elimination — P07 O1–O3/O5 class) | P04, P07 | The IR is the contract every emitter, wave, and later plan builds on. Freezing it in v1 is what makes Waves 2–3 additive instead of rewrites (P14 §3, P15 §7.3 make the same bet). |
| M5 | **Emitters — all three families:** `--target json` (v1 legacy `{triangles:[…]}` **and** v2 scene format), `--target html` (self-contained page), `--target fortran` (generated scene program), plus `--target js` runtime bundle | P04 §6, P06, P17 §8 | The task's definition of the shippable compiler. JSON keeps today's `viewer.html` working (P04 phase c); HTML is the zero-install demo; Fortran is the native path and the escape hatch P01 R6 requires be disclosed, not hidden. |
| M6 | **Native render path:** Fortran scene reader / generated-program driver so a compiled scene — not just the hard-coded demo — renders through the existing rasterizer to PPM (P3 kept; P6 per P17 §4) | P05, P17 §§4,7,9 | "Compiler to Fortran" that cannot be executed is a print statement. This is also the seam OBJ import (P15 §8) and multi-object rendering (P16 §6) attach to. |
| M7 | **Multi-object scenes, flat + one level of groups:** many object lines, TRS composition in the one fixed order, compiler flattening to flat backend payloads; scene caps enforced as errors, never truncations | P12, P16 §§3.1,8 | P01 task 6 (10 objects) is a census headline. Depth ≤1 is a *v1 sequencing* choice (P12 §11) — deeper graphs are Wave 2 (§5), not refused. |
| M8 | **Materials & lighting, honest core:** one `Material` (`color`, `emissive`, `opacity`, `specular`, `shininess`, `shading`), `flat` + `lambert` shading, one ambient + directional lights (cap stated, error on exceed) | P10 §§3,5 | A lit sphere in ≤4 lines (P01 task 2) requires lighting to be a default, not a subsystem. This is deliberately the *non-PBR* model — PBR is Wave 3 (§5), scheduled, not denied. |
| M9 | **Simple animation:** declarative `spin` / `move` / `bob` / `pulse` + simple keys with the v1 easing set, delta-timed by the runtime; user writes no loop, clock, or render call | P03 §7, P09 §§4,6 (v1 half) | P01 tasks 1 and 5: the rotating cube is the flagship demo and the loop is 0 authored lines. Full keyframes are Wave 2 (§5). |
| M10 | **Viewer:** WebGL viewer (Canvas 2D fallback) consuming the v2 scene format, <15 KB core runtime, orbit/pan/zoom with damping, auto-rotate, presets, runtime-owned resize/aspect/pixel-ratio | P06, P13 §§3–7 | P01 tasks 4 and 10 at 1 and 0 lines respectively. The size budget (P06 §10, gated in P19 §7.1) is what keeps "tiny viewer" a fact instead of a slogan. |
| M11 | **CLI:** `f3dc` with `new` / `check` / `build` / `run` / `fmt`, zero-config defaults, one-command-to-a-picture path, graceful degradation when `gfortran` is absent (web targets still build) | P20, P04 §10 | The ease claim lives or dies at the first terminal session (P20 §0 north-star metrics). A compiler you must hand-assemble fails §1 before the DSL is even read. |
| M12 | **Tests:** Fortran unit tests, compiler unit tests (lexer/parser/validator/emitters), golden-image tests incl. the legacy cube, error-message golden fixtures | P18 | Every other Must item is a claim; this is the evidence. P18 §9: tests land *with* each pipeline phase, never after. |
| M13 | **CI:** one workflow — Fortran build, compiler tests, golden render check, JS size check, docs lint — failure artefacts first | P19 | The user's standing pattern for this project family is CI-verified, not locally asserted. A milestone that is green only on one machine has not shipped. |
| M14 | **Render targets, core:** PPM stills, animation frame sequences with the normative `frame_%04d` naming, deterministic output naming/overwrite rules shared by `engine3d` and `f3dc` | P17 §§3,4,6,7 | Stills + frames are what M9 animation and the golden tests (M12) output. Naming drift between the two drivers is a beginner trap P17 exists to close. |

### v1 ship gate (all must be true, all checkable)

1. The P03 3-line rotating-cube program compiles and renders correctly
   on **all three** target families (M5) — parses alone does not count
   (P01 §5 preamble).
2. Legacy golden passes pixel-identically (invariant 3); every P11
   primitive passes its P11 §10 acceptance tests.
3. Every reserved/not-yet-wave keyword produces its named Wave-N
   diagnostic — a test fixture, not a code review opinion (M2, P14 §11.1).
4. CI (M13) is green on the full matrix, including the JS <15 KB check.
5. README and docs describe v1 as **milestone 1 toward parity** and
   print the wave table (§§5–6) — no parity or performance claim that
   §7/§8 has not earned.

---

## 3. SHOULD — planned for v1, may slip to Wave 2 by the §6 rule

| # | Item | Owner | Why Should, not Must | If it slips |
|---|---|---|---|---|
| S1 | **OBJ import, v1 subset:** `load "model.obj"`, fan triangulation, positive + negative indices, groups → named objects, `vt`/`vn` parsed-then-honestly-discarded with one summary warning, `.mtl` not loaded with warning | P15 §§3–6 | P01 task 8 is a census headline, but §1's promise is provable with primitives alone; import is the largest single new Fortran module in the plan set | Wave 2, first item — and glTF (W2-2) must not overtake it, since P15 §7.3's format-neutral seam is built here |
| S2 | **`phong` shading mode** (per-pixel Blinn–Phong-lite, same equation as M8 evaluated per-pixel) | P10 §3.3 | Visibly better spheres, but per-pixel cost on a CPU rasterizer is opt-in economics (P10 §2.6); `flat`/`lambert` already satisfy task 2 | Wave 2; keyword stays reserved-and-rejected, never silently downgraded to `lambert` |
| S3 | **Point lights** (within the M8 light cap) | P10 §5.3 | Directional + ambient covers every v1 example; point lights add attenuation validation and per-light cost to the inner loop | Wave 2 alongside spotlights (W2-5), sharing the same light-list machinery |
| S4 | **`shadow: blob`** — the explicitly-named fake ground shadow | P10 §7.2 | It is honest (its name says fake) and cheap, but it is garnish on §1, not load-bearing | Wave 2; real shadow maps are W2-4 regardless — blob never substitutes for them in any claim |
| S5 | **Placement helpers:** `repeat` / `grid` / `line` / `ring` as compile-time expansions with deterministic naming (`wall#37`) | P16 §3 | Many plain lines (M7) already satisfy the 10-object census task; helpers are the "better than Three.js" flourish, and their caps/naming rules deserve unhurried tests | Wave 2; expansion semantics (P16 §4) are frozen now so the slip is implementation-only |
| S6 | **PNG via PPM conversion** (external converter, properly specified — not today's ad-hoc `Makefile` step) | P17 §5 Phase 1 | PPM is the native, testable format (M14); PNG-for-sharing is convenience. Native PNG is Wave 2 (W2-7) | Wave 2; docs must keep calling the conversion a conversion |
| S7 | **`f3dc doctor`, shell completion, editor glue** | P20 §§6.3–6.4 | Doctor shortens support loops but the golden path (M11) must work without it | Wave 2; P20 already specifies it as v1.1-class work |
| S8 | **Advanced safe optimisations:** static mesh merge, frustum/backface culling *hints* emitted to backends | P07 §§4.3–4.6 | Hints must never change a pixel; proving that is test work (M12) that can follow the IR freeze (M4) | Wave 2; LOD hints are Wave 3 (W3-8) in any case |

---

## 4. How deferral is justified — the four tests

A feature may be placed in Wave 2/3 only if it passes **at least one**
of these tests, and the table in §5 names which test each feature used.
This replaces justification-by-taste:

1. **Dependency test:** it needs a v1 Must item that does not exist yet
   in code (a UV field, an alpha channel, a format-neutral mesh seam)
   and building the dependency *and* the feature in one milestone would
   land both untested. (Textures, glTF, smooth imported normals.)
2. **New-failure-surface test:** it adds a decoder, a per-pixel path, a
   second shading frequency, or a browser/native split — each a whole
   class of beginner-visible bugs — for a benefit a colour word already
   approximates in v1. (Textures again: P14 §1.2 counts five surfaces.)
3. **Cost-honesty test:** on a CPU software rasterizer (native) and a
   <15 KB WebGL1 runtime (browser), its cost cannot yet be *measured and
   published* — and unmeasured features are how false FPS/speed claims
   are born (§8). (Shadow maps, per-pixel PBR, real GPU instancing.)
4. **Contract-risk test:** its semantics, once shipped, are expensive
   to change (UV origin/flip, glTF coordinate conversion, keyframe
   tangent model) and therefore deserve their own design-freeze moment
   after v1's IR and golden infrastructure exist to lock them with
   tests. (P14 §2, P09 §6, P12 §11 all argue exactly this.)

No feature is deferred for being "out of character", "too advanced for
beginners", or "not needed" — under the parity goal those are not
reasons. If a feature fails all four tests, it belongs in Must/Should
and §5 is wrong; fix §5.

---

## 5. WAVE 2 — complete common authoring parity

*Theme: everything a weekly Three.js/PixiJS user reaches for. Entry
condition: v1 ship gate (§2) green. Exit condition: every row has a
running implementation + acceptance tests named in its owner plan.*

| # | Item | Owner | Deferral test(s) | Notes / entry criteria |
|---|---|---|---|---|
| W2-1 | **Textures & UVs, full P14 design:** per-primitive UV generation, perspective-correct sampling, PPM/PGM + BMP native, PNG/JPEG in browser, `--textures` flag family, frozen origin/flip/multiply rules | P14 | 1, 2, 4 | The single largest Wave 2 item. v1's only texture work is reserve + reject (M2). P01 task 3 (textured plane ≤3 lines) is *met in this wave*, and docs say so |
| W2-2 | **glTF / GLB import** on the format-neutral seam, incl. node hierarchies mapped to P12 groups and glTF materials mapped to the P10 model where they overlap | P15 §7 | 1, 4 | Interim v1 behaviour is the specified diagnostic + "convert to OBJ" path (P15 §7.4). PBR-only glTF fields wait for W3-1 and must warn, not drop silently |
| W2-3 | **Full keyframes:** tangents, blending, triggers/events, camera/light tracks, `fade` (once alpha exists) | P09 §§6 (v2 half), 7–9 | 1, 4 | v1 simple keys (M9) are the subset; the IR timeline reservation in P04 §12 is what makes this additive |
| W2-4 | **Real shadows:** shadow maps, one declaration site (`shadows on`, P01 R4), fitted shadow camera, sane bias default | P10 §7.3 | 2, 3 | P01 task 7 is the most-flag-scattered feature in Three.js (5 places); doing it in one place, correctly, is a headline parity-plus win — and exactly why it is not rushed into v1 |
| W2-5 | **Spotlights** + point lights if S3 slipped; light cookies remain Wave 3 | P10 §5 | 2, 3 | Completes the P10 light family (ambient/directional/point/spot) |
| W2-6 | **Smooth shading from imported normals:** loaded `vn` actually used; `.mtl` materials loaded and mapped | P15 §§4.6, 5.4 | 1 | Removes v1 OBJ's two documented discards (S1). Claiming MTL support before this wave is the fake P15 §0 forbids |
| W2-7 | **Native PNG writer** (no external tool at runtime) | P17 §5 Phase 2 | 1, 2 | Replaces S6's conversion path; PPM remains the golden-test format |
| W2-8 | **Fly / first-person camera** as an explicit `controls fly` mode switch | P13 §9 | 2, 4 | Different state + input model; P13 lays the groundwork in v1 (true position/target camera, WASD reservation) precisely so this is additive |
| W2-9 | **Deeper scene graph:** groups-in-groups to a *stated* new depth cap, quaternions/axis-angle, negative-scale mirroring rules, group colour/material inheritance | P12 §11 | 4 | Each sub-item needs its own ruling per P12; depth rises to a number, never to "unlimited by accident" |
| W2-10 | **Real instancing paths:** JS `ANGLE_instanced_arrays` behind capability check; per-placement colour/phase variation beyond S5's basics | P16 §§7, 3.3 | 3 | Pseudo-instancing (shared buffers, per-placement uniforms) is already the P16 design; this row is the measured optimisation of an identical scene, never a semantic change |
| W2-11 | **Whatever slipped from Should** (S1–S8), taken in §3's stated order | — | — | Slips land here automatically; they do not need re-justification, and they go first |

---

## 6. WAVE 3 — complete advanced / ecosystem parity

*Theme: the rest of the combined Three.js + PixiJS-3D surface. Entry
condition: Wave 2 exit. Each row requires its own numbered plan
(P29+) before build — a row here is a commitment to scope and schedule
that work, not a vague intention.*

| # | Item | Source / seed | Deferral test(s) | Notes |
|---|---|---|---|---|
| W3-1 | **PBR materials:** metalness/roughness workflow, normal/bump maps, env/IBL, reflections, refraction, gamma + tone mapping, physically-correct colour pipeline | P10 §0 non-goals list, P02 §2 row 8, P14 §12 | 1, 2, 3 | The honest inverse of M8: v1's model is explicitly *not* physically correct (P10 §0) and docs say so until this lands. Includes cube/environment maps and emissive bloom's material half |
| W3-2 | **Custom shaders / materials:** user GLSL in the viewer, shader chunks, on-the-fly material definitions — with a DSL escape hatch audited against P01 R6 so it does not quietly become raw Three.js again | P01 R6, P06 §1.2 | 2, 4 | Native Fortran path gets a defined subset or a defined diagnostic — parity of *claim* matters as much as parity of feature |
| W3-3 | **Post-processing:** render-target chains, bloom, DOF, FXAA/MSAA choices, output colour-space passes | P17 (targets), P06 §1.2 | 1, 3 | Render targets beyond the framebuffer (P17's full matrix) are the dependency |
| W3-4 | **Skeletal & morph animation:** skinning, bones, blend shapes, animation mixing/clips from glTF | P06 §1.2, P09 | 1, 2 | Depends on W2-2 (glTF) and W2-3 (full keyframes); the largest single Wave 3 item |
| W3-5 | **Particles, points, lines, sprites:** DSL-first (`particles 1000 in sphere …`, P01 task 9 at ≤3 lines, no typed-array vocabulary) | P01 §5 task 9, P02 | 2 | A census task, therefore ledger-tracked (§7) even though no P01–P20 plan owns it yet — first Wave 3 plan to be written |
| W3-6 | **Text & advanced geometry:** text rendering/geometry, extrude/lathe/tube-style parametric geometry, CSG if a plan justifies it | P03 §11 (text deferred there) | 2, 4 | Font handling is a dependency and licensing decision, not just code |
| W3-7 | **WebGL2 path + GPU compute-adjacent features,** while WebGL1 remains the compatibility floor | P06 §§1.2, 3 | 3 | One code path was a v1 virtue (P06); a second path is bought only with measured benefit |
| W3-8 | **LOD, spatial partitioning, large-scene tooling:** LOD hints activated, octree/BVH options, scene budgets beyond P16 §9's published zones | P07 §4.7, P16 §9 | 3 | Guidance numbers must be re-measured per wave (§8), never carried forward as folklore |
| W3-9 | **Interaction layer:** raycasting/picking, physics helpers, audio hooks — as add-on modules, never core-runtime growth | P06 §§1.2, 8.3 | 2 | P06's rule stands in all waves: add-ons are separate files; the <15 KB core contract is permanent |
| W3-10 | **Ecosystem long tail:** remaining loaders (FBX, STL, PLY, HDR/EXR env), remaining controls (trackball, transform gizmos), WebXR, PixiJS interop/bridge examples | P01 §4 rows 6–7, P02 §4 | 1, 2 | Each gets a ledger row (§7) and a plan or an explicit "via external converter to OBJ/glTF" supported path — a documented conversion path *is* a parity answer when it is tested, an undocumented one is not |
| W3-11 | **Packaging ecosystem:** package-manager submission (PyPI/Homebrew), localised docs, GUI wrapper if user demand is shown | P20 §§5, 12–13 | 2 | P20 already rules these out of *v1* scope; here they are scheduled product work, gated on demand evidence per P20 §13 |

### The slip rule (applies to every wave)

1. A slipping item moves exactly one wave later, by an edit to this
   file in the same change that reports the slip — reason + new wave.
2. A slipped item keeps its owner plan, its acceptance tests, and its
   reserved syntax/diagnostics. Nothing about its *meaning* changes.
3. Two consecutive slips of the same item require a written blocker
   analysis (dependency, cost, or contract — §4) appended to its owner
   plan. Silence is not a slip mechanism.

---

## 7. Parity ledger — how "full parity" stays falsifiable

Parity is claimed per-row, never globally, until every row is ✅.
The ledger lives in this file until Wave 2 opens, then moves to its
own tracked document with the same columns.

| Census surface (P01 tasks / P02 rows) | Wave | Owner | Status at v1 |
|---|---|---|---|
| Rotating cube, lit sphere, animation loop, resize (tasks 1, 2, 5, 10) | v1 Must | M1, M8–M10 | 🎯 v1 ship gate §2.1 |
| 10-object scene (task 6) | v1 Must (+S5 helpers) | M7, S5 | 🎯 |
| Orbit camera (task 4) | v1 Must; fly = W2-8 | M10, P13 | 🎯 / Wave 2 |
| OBJ load (task 8) | v1 Should; glTF = W2-2, MTL = W2-6 | S1, P15 | 🎯 Should |
| Textured plane (task 3) | Wave 2 | W2-1, P14 | Reserved + rejected in v1 |
| Shadows (task 7) | Wave 2 (blob fake = S4) | W2-4, P10 §7 | Rejected in v1, named |
| Particles (task 9) | Wave 3 | W3-5 | Rejected in v1, named |
| PBR / lights / materials depth (P02 rows 7–8) | v1 core → W2-5 → W3-1 | M8, P10 | Partial by design, docs state it |
| Loaders/controls ecosystem (P01 §4 rows 6–7) | Wave 3 | W3-10 | Conversion path documented |

Any Three.js/PixiJS feature discovered later that has **no ledger
row** is a defect in this plan: add the row, assign a wave by the §4
tests, and write the plan. Discovery never creates a Won't.

---

## 8. What is actually refused (not features — claims and fakes)

These are permanent, in every wave, and are the *only* refusals:

1. **No unmeasured performance claims.** No FPS number, "fast",
   "real-time", or budget-zone figure may appear in README/docs/release
   notes unless it names hardware, scene (triangle/placement counts),
   target (native/WebGL), and the benchmark run that produced it.
   P16 §9's zones (green ≤25k tris native / ≤100k WebGL, etc.) are
   *guidance to be re-measured per wave*, not claims. This gates the
   claim, never the feature — optimisation work itself is M4/S8/W2-10/
   W3-8.
2. **No fake support.** No keyword accepted-and-ignored, no texture
   silently rendered as a colour, no shadow flag that draws nothing,
   no `.mtl`/glTF material silently dropped without the specified
   warning (P10 §2.2, P14 §8, P15 §4.6).
3. **No silent scope deletion.** §6's slip rule is the only way an
   item changes wave. A feature absent from §§2–6 and §7 does not
   exist as a decision — see §9.
4. **No parity claim ahead of the ledger** (§7), and no "easy" claim
   ahead of the P01 §5 line-count re-census that P20/P04 require at
   each wave exit.

---

## 9. Assigning P21–P27 and future plans

Plans P21–P27 were not in `docs/plan/` when this plan was audited;
nothing in §§2–6 assumes their contents. When each lands, its author
must, in that plan or by a P28 amendment:

1. Register every feature it introduces in the §7 ledger.
2. Assign each feature Must / Should / Wave 2 / Wave 3 using the §4
   tests, naming the test(s) used.
3. State its reserved-syntax diagnostic for any feature not in v1.

Default if a plan is silent: its features are **Wave 2** if they pass
any §4 test, **Should** if they pass none — never unlisted, never
Won't. The same rule applies to any P29+ plan created for Wave 3 rows.

---

## 10. Risks & open questions

1. **Wave inflation:** Waves 2–3 are large. The mitigation is structural,
   not rhetorical: v1's IR freeze (M4), format-neutral seam (S1/W2-2),
   and reserved-syntax rule (M2) are precisely the investments that keep
   later waves additive. If v1 ships without them, this plan has failed
   even if the demo works.
2. **Two-renderer parity drift:** native Fortran and JS viewer must
   render the same scene the same way (P12 §10.3, P14 §11.4). Each wave
   exit needs a cross-target golden set, or "parity" quietly splits
   into two products.
3. **P01 contract vs. parity tension:** Three.js's hardest tasks
   (shadows, textures, loaders) are where the ≤⅓-lines contract is
   hardest to keep. Wave exits re-run the census (P01 §5, R6) rather
   than assuming the v1 result carries over.
4. **Open for owner ruling:** (a) Is S1 (OBJ) promoted to Must if the
   v1 schedule allows only one of S1/S5? This plan's recommendation:
   S1 first — it is a census task; helpers are not. (b) Does Wave 3
   open per-row (each row on its own plan's schedule) or as one wave
   gate? Recommendation: per-row, with the §7 ledger as the only
   global gate on the parity claim itself.
