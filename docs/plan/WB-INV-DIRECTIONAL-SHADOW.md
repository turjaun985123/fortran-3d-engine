# WB-INV — Directional shadows: Wave A anomaly investigation (seat B97)

**Verdict (one line):** Directional shadows are broken for near receivers by
frustum/bias geometry — in `src/main.f90` the directional shadow camera sits
30 units away with near 0.5 / far 80, so at the receiver the NDC-depth gap
between caster and ground is Δz ≈ 0.00135, **smaller than the fixed bias
0.002** hard-coded in `renderer.f90`'s `draw_triangle_env`, and the shadow is
swallowed (only the far-offset fringe of the footprint, where the
caster→receiver distance is larger, survives). A second, stacked cause made
the original probe read as *exactly* zero: with the conventional
above-the-plane camera the ground plane rasterises **zero pixels at all**
(far-side winding convention), so there is no receiver surface in the image
for a shadow to darken. The coordinator's bias hypothesis is **confirmed as
the primary mechanism**, with the plane-visibility quirk as a contributing
cause of the "zero difference" observation.

**Row 16 recommendation:** downgrade the directional part of the claim.
Spot/point shadows and the shadow module remain verified (Wave A evidence
stands); *directional end-to-end* must read "broken for receivers within
~2 view-units of the caster (bias-swallowed); no visible shadow in the
standard ground-plane setup" until the fix in §5 lands and is re-verified.
Do **not** keep Row 16 as fully backed for directional on current evidence.

All renders/probes were run in `/tmp/b97` (scenes, PPMs, throwaway Fortran
probes `probe.f90` / `probe2.f90` / `probe3.f90` linking the repo's built
objects). No source or test file was modified; `make` reported
"Nothing to be done" (binary already current).

---

## 1. Reproduction — directional-only, spot-free scenes

Scene A (320×240, default directional light only, cube caster over a
ground plane; syntax per `examples/lighting-showcase.f3d` /
`tests/e2e/test_wavea_e2e.py` `SHADOW_SRC`):

```
scene "dirshadow" size 320 240 background black shadow on      # off / soft variants
camera at 6 4 9 look 0 -1 0
light directional
light ambient strength 0.15
plane ground gray at 0 -2 0 size 18 material standard metalness 0 roughness 0.95
cube hero white at 0 0 0 size 2 material standard metalness 0 roughness 0.8
render still
```

Compiled/rendered with
`python3 tools/f3dc/f3dc.py run <scene>.f3d -o <dir>`; differing pixels
counted with a stdlib PPM parser (`/tmp/b97/diff.py`):

| Comparison | Result |
|---|---|
| Scene A `shadow on` vs `shadow off` | **0 differing pixels**, max channel Δ = 0, identical MD5 `16ad41cc…` |
| Scene A `shadow soft` vs `shadow off` | **0 differing pixels**, same MD5 |
| Scene B = B61's exact `SHADOW_SRC` geometry (160×120, same plane/cube/spheres, spot+point **removed**, directional + ambient only) `on` vs `off` | **0 differing pixels**, identical MD5 `ce36a626…` |

The anomaly reproduces exactly as logged in `docs/WAVE-A-REPORT.md`.

## 2. The mechanism, quantified (Fortran probe against the real modules)

Probe (`/tmp/b97/probe.f90`) loads the compiled Scene A `.scene` via
`scene_3d`, replicates `main.f90`'s shadow block verbatim, and inspects the
resulting `ShadowMap`:

- Receiver point = centre of the expected shadow: the cube's bottom centre
  `(0,-1,0)` stepped along the light direction `(-0.5,-1,-0.7)` to the
  plane `y=-2` gives **`(-0.5,-2,-0.7)`** (1.319 ray-units behind the
  cube's exit face).
- That point's light-space NDC z = **0.981208**; stored shadow-map depth at
  its pixel (256, 265) = **0.979861**.
- **Δz = 0.001347 < bias 0.002** → `shadow_factor(smap, p, 0.002)` = **1.0
  (lit)**. With bias 0 the same call returns **0.0 (shadowed)**. The depth
  data is correct; the bias alone flips the verdict at the shadow centre.
- Grid scan of the whole plane (`y=-2`, 0.25 spacing, in-frustum samples):
  **4,225 samples; 76 shadowed at bias 0.002 vs 174 shadowed at bias 0.**
  The surviving 76 sit at the footprint's far-offset fringe
  (x ≈ −2.75…−2.0, z ≈ −3.25…−0.5), where rays exit the cube's side faces
  and travel farther to the plane — i.e. the shadow is not absent, it is
  **eroded by ~2 view-units from the caster**, which for a 2-unit cube
  floating 1 unit over the plane removes its centre.

Analytic cross-check (Python, replicating `mat4_perspective`):
z_ndc(d) = (f+n)/(f−n) − 2fn/((f−n)·d), so dz/dd = 2fn/((f−n)·d²).
Receiver view-depth d = 30 + 2.077 = **32.08**; dz/dd = **0.000978/unit**;
over the 1.319-unit caster→plane gap Δz ≈ **0.00129** (probe: 0.001347 —
agreement within rasterisation of the stored depth). Ratio to bias:
**0.64×**. For comparison, B61's spot at ~8.9 units: dz/dd ≈ 0.0127/unit,
Δz ≈ 0.0168 ≈ **8.4× bias** — which is why spot/point shadows survive the
same bias and directional does not. The coordinator's arithmetic
(~0.00066/unit at d≈39, Δz≈0.0013) is confirmed in shape and conclusion;
the exact receiver depth here is 32.08, giving 0.00098/unit.

## 3. Other suspects — ruled in / out with evidence

**(a) `main.f90` light-selection loop / directional fallback — RULED OUT.**
Probe prints for the directional-only scene: `lights%items` has size 1
(kind 0, the assembled directional). The loop runs to completion, leaving
`li = 2 > size = 1`, so the fallback **is** taken:
`sh_pos = (11.371, 22.743, 15.920)` = −30·normalize(−0.5,−1,−0.7),
`sh_tgt = (0,0,0)` — exactly as the code intends.

**(b) Shadow map empty / no depth — RULED OUT.** The combined map has
**1,512 of 262,144 cells filled**, depth range **0.97799…0.98080** (not the
`1e10` sentinel). The depth is there; it is the *comparison* that fails.

**(c) Winding culling emptying the map — RULED OUT for the caster, RULED
IN for the plane.** Per-object maps (`probe2.f90`): cube alone fills all
1,512 cells; **plane alone fills 0 cells** — the plane's two triangles are
winding-culled from the light's viewpoint, so a plane never *casts* into
the map. That does not cause this anomaly (the plane here is the receiver;
its own depth is not needed), but it is a real secondary defect for any
scene where a plane must cast.

**(d) Receiver not on the env path (`has_env` gating) — RULED OUT.**
Probe: `has_env = T`, `shadow_mode = 1` for Scene A (the `shadow` line
sets `has_env` in `scene.f90`, and `standard` materials set it too). §4's
from-below render proves the env path + shadow lookup run end-to-end.

## 4. Contributing cause: the receiver plane is invisible from above

Plane-only renders (shadow off) at 160×120 and 320×240:

| Camera | Plane pixels rendered |
|---|---|
| (6,4,9), (5,3,7), (−6,4,9), (6,4,−9), (−6,4,−9), (3,2.5,4), (12,6,0), (0,8,0.5) — all above the plane | **0** |
| (0,−6,12) — below the plane, looking up | **499** (size 12, 160×120) |

This is the known far-side winding convention applied to a single-sided
plane: from above it is culled entirely (same family as the Wave A
report's "large-plane rasterisation" quirk). Consequence: in the standard
showcase-style setup (Scene A/B), **no on/off difference could appear on
the plane even with a perfect shadow map** — the only rendered surfaces
are the casters themselves. (This also means the "ground-plane pixels"
attribution in B61's spot test deserves re-checking: at that camera the
plane contributes no pixels, so the darkened pixels there belong to
another object.)

Control experiment — same Scene A geometry, camera moved below the plane
(`camera at 0 -6 12 look 0 -1 0`, 320×240) so the receiver actually
rasterises (49,712 plane pixels):

| Comparison | Result |
|---|---|
| `shadow on` vs `shadow off` | **1,038 differing pixels**, all plane pixels darkened (111,111,115) → (21,21,21) (ambient-only) |

And the darkening is visibly *partial*: inside the darkened region's
bounding box (x 218–292, y 80–110) there are 2,325 lit plane pixels in the
off render, of which only 1,038 darken — the bias-eroded fringe shadow of
§2, not the full footprint. Directional shadowing therefore works
end-to-end only where caster→receiver separation exceeds ~2 view-units.

## 5. Recommended fix (exact)

**Primary — fit the directional shadow frustum to the scene in
`src/main.f90`** (shadow block, directional fallback branch only;
spot/point branch untouched):

1. Compute a scene radius `R` = max over objects of
   `|pos| + bounding_radius(prim, extents)` (the `object_extents` helper
   already in `main.f90` supplies the per-prim sizes).
2. Replace the fixed placement/frustum for the directional case:
   - distance `D = R + 10`; `sh_pos = -normalize(sc%light_dir) * D`,
     `sh_tgt = (0,0,0)` (unchanged target);
   - `near = max(0.5, D - R - 5)`, `far = D + R + 5`
     (pass these to `shadow_begin` instead of the current literal
     `60.0, 0.5, 80.0` when the fallback was used; keep fov 60).

Verified effect of this fit, measured with `probe3.f90` (same scene,
same bias 0.002, only `shadow_begin` parameters changed):

| Frustum | Centre Δz | vs bias | Centre `shadow_factor` | Grid samples shadowed |
|---|---|---|---|---|
| Current: D=30, near 0.5, far 80 | 0.001347 | 0.67× | 1.0 (lit) | 76 / 4,225 |
| Fit instance A: D=12, near 1, far 30 | **0.014478** | **7.2×** | **0.0 (shadowed)** | 215 / 3,203 in-frustum |
| Fit instance B: D=20, near 5, far 40 | **0.032395** | **16.2×** | **0.0 (shadowed)** | 182 / 4,186 |

(Instance B is what the formula above yields for a ~10-unit-radius scene;
A shows even a minimal tightening works. Analytic estimates — 0.0138 and
0.0309 — match the measured Δz.)

**Not recommended as the fix on its own:** merely shrinking the bias in
`renderer.f90` (`shadow_factor(smap, wp, 0.002)` in `draw_triangle_env`).
Bias 0 would flip this scene's centre, but with dz/dd ≈ 0.001/unit *any*
fixed bias is scene-scale roulette — too large eats near shadows, too
small invites acne from the far-side depth convention noted in
`shadow.f90`'s header. If touched at all, make the bias a fraction of the
fitted frustum's depth range *after* the frustum fit, and re-run the
spot/point e2e (`test_shadow_soft_darkens_plane_pixels`) to confirm no
acne regression there.

**Separate items, not this fix:** (i) plane triangles cast nothing into
the shadow map (§3c) and render nothing from above (§4) — the plane
winding/rasterisation investigation owns those; the frustum fix should be
re-verified with a *visible* receiver (e.g. the from-below scene of §4, or
a box ground) rather than the showcase camera, which cannot show a plane
shadow either way.

## 6. Re-verification checklist for whoever lands the fix

1. Scene A frustum probe: centre Δz ≥ 5× bias and `shadow_factor` = 0 at
   (−0.5,−2,−0.7).
2. From-below scene (§4): on/off differing pixels ≫ 1,038 and the lit hole
   inside the footprint gone (darkened ≈ all plane pixels in the
   footprint bbox).
3. Wave A e2e shadow test (spot) and showcase A/B still pass — the
   spot/point branch must be byte-identical in behaviour.
4. Only then restore Row 16's directional claim to Done-verified.
