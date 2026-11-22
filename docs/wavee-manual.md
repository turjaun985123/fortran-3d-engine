# Forge3D User Manual — Wave E chapter

This chapter is the Wave E section of the manual (custom shaders,
skinning and morph targets, WebGL2, and XR). It is written to be
linked into `docs/manual.md` at integration; it follows that
manual's style and numbering continues from its §7.

Worked example shipped in `examples/`: `wavee-showcase.f3d`
(two shader-bound objects, one morphed sphere, one skinned
cylinder, in a single scene).


## 8. Wave E: shaders, skinning and morphs, WebGL2, XR

Wave E adds four features. Two of them are `.f3d` language
(§8.1 custom shaders, §8.2 skinning and morph targets); two of
them are viewer runtime features that need **no** `.f3d` lines
at all (§8.3 WebGL2, §8.4 XR) — the same scene file renders
through all of them.


### 8.1 Custom shaders (C2)

The easy form is two lines: define a shader once, then bind it
to an object with the `shader` property.

```f3d
shader checker expr "c * step(0.5, fract((x + y) * 2))"
cube red shader checker
```

- `shader <name> expr "<expr>"` — a scene-level statement that
  defines a named per-pixel channel expression. It draws nothing
  by itself.
- `shader <name>` — an object property (like `material` or
  `at`), usable on any object line, that binds a previously
  defined shader to that object.

A minimal second shader, visibly different from the first:

```f3d
shader stripes expr "c * (0.5 + 0.5 * sin(x * 4))"
sphere blue radius 1 shader stripes
```

**Semantics, in plain language.** For every pixel of a bound
object, the expression is evaluated once per colour channel.
The result **replaces** that channel's value, and is clamped to
the range 0..1 before it is written. The expression is a single
arithmetic formula — no statements, no loops, no assignments —
over these variables:

| Variable | Meaning |
|---|---|
| `c` | the channel value being computed (the lit colour for this channel, before the shader) |
| `r` `g` `b` | the object's base colour channels |
| `x` `y` `z` | the point's position |
| `u` `v` | the point's surface (texture-style) coordinates |
| `ndl` | the Lambert diffuse term (N·L) for this point — how directly it faces the light |
| `t` | time, in seconds |
| `pi` | the constant π |

Functions: `sin cos tan abs sqrt floor ceil fract min max step
pow clamp mix`. Operators: `+ - * / % ^` (with the usual
parentheses). That list is the whole language: a name outside
it is a compile-time error, not a silent no-op.

Because `ndl` is available, ordinary lit shading is itself a
shader, and is a good starting point for your own:

```f3d
shader lit expr "c * (0.25 + 0.75 * ndl)"
```

That expression keeps a quarter of the channel everywhere (so
back faces are not pure black) and adds the rest in proportion
to how directly the point faces the light — exactly the shape
of the built-in Lambert shading.

**Limits and honesty notes.**

- **Division by zero yields 0.** A guarded division returns 0
  instead of infinity, NaN, or a crash, so a formula like
  `c / (x - y)` is safe to write even where `x` equals `y` —
  those pixels simply get 0 from that division.
- This is **not GLSL** and not a general programming language:
  one expression, the variables and functions listed above,
  nothing else. There is no way to read neighbouring pixels,
  keep state between pixels, or loop.
- A shader changes **colour only**. It does not move vertices
  (that is §8.2), change which pixels an object covers, or
  affect any object it is not bound to.


### 8.2 Skinning and morph targets (C1)

#### Morphs

The easy form is an ordinary object line, then one `morph`
line naming it:

```f3d
sphere bulgy green radius 1
morph bulgy bulge 0.5
```

- `morph <target> <kind> <factor>` — `target` is the name of an
  object already defined; `kind` is one of `bulge`, `taper`,
  or `squash`; `factor` is a number saying how much.

**Semantics, in plain language.** A morph reshapes the target's
vertices before rendering, by an amount scaled by `factor`:

- `bulge` — pushes vertices **outward** from the object's
  centre, most strongly around its middle (equator), so the
  object swells.
- `taper` — **narrows** the object progressively toward one
  end, so a uniform shape leans toward a point or a waist.
- `squash` — **compresses** the object along one axis, so it
  gets shorter and, in effect, squashed down.

In every case the displacement of each vertex is its direction
of reshaping multiplied by `factor` — which is why **factor 0
is the identity**: every displacement is multiplied by zero,
and the object renders exactly as defined. Larger factors
reshape more; there is no separate "amount" property.

#### Skinning

The easy form is three lines: a named object, a `bone`, and a
`skin` line binding the two.

```f3d
cylinder pillar yellow radius 1 height 3
bone spine at 6,0,0 rotate 0,0,20 radius 2.5
skin pillar spine
```

- `bone <name> at x,y,z rotate rx,ry,rz radius r` — defines a
  named bone: a pivot point (`at`, comma form), a rotation in
  degrees (`rotate`, comma form), and a reach (`radius`). A
  bone draws nothing by itself.
- `skin <target> <bonename>` — binds the named object
  (`target`) to the named bone.

**Semantics, in plain language.** Skinning moves the target's
vertices **as if** they were attached to the bone with a soft
weight. Each vertex's weight comes from its distance to the
bone's pivot: a vertex at the pivot has weight 1 and is rotated
fully by the bone's `rotate`; the weight then falls off
**smoothly** as the distance grows, and a vertex at or beyond
the bone's `radius` has weight 0 and does not move at all. The
vertex's final position is the blend, by that weight, between
its original position and its fully bone-rotated position. A
small weight near the edge of the bone's reach is what makes
the object **bend** around the pivot instead of snapping or
moving as one rigid piece.

**Limits and honesty notes (morphs and skinning).**

- Both are **vertex** effects: they change the shape an object
  presents, not its colour (that is §8.1) and not its declared
  position — the object's `at` is unchanged; its vertices move
  relative to it.
- The formulas above are deliberately stated in words: bulge,
  taper, and squash are smooth, factor-scaled displacements,
  and skinning is a smooth distance-falloff blend. They are
  simple deformations, not a physics simulation and not a full
  skeletal-animation system: a `skin` line binds **one** object
  to **one** bone, there is no bone hierarchy, and there are no
  keyframed bone animations in the `.f3d` form.
- A morph or skin line naming an object or bone that does not
  exist is an error, in line with the manual's existing rule
  for unknown animation targets (§2.8) — it is not ignored.


### 8.3 WebGL2 backend (C3)

There is **no `.f3d` form** for this feature, on purpose: the
scene does not change, only the viewer's drawing backend does.
Any existing scene is already a complete example:

```f3d
cube red
spin it
render
```

**Semantics, in plain language.** The viewer's WebGL2 support
lives in a sidecar runtime file, `runtime/f3d-webgl2.js`,
alongside the existing player (§5). When a viewer page loads
it, the sidecar **feature-detects** WebGL2 in the visitor's
browser: where WebGL2 is available it renders the scene through
WebGL2; where it is not, it **falls back to the Canvas2D
renderer** — the same scene, the same API, drawn the slower,
universally supported way. The author of a scene writes nothing
and chooses nothing; detection and fallback are the runtime's
job.

**Limits and honesty notes.**

- Fallback is a **compatibility** guarantee, not a speed one:
  a browser without WebGL2 gets the same picture through
  Canvas2D, not the same frame rate.
- WebGL2 availability is a property of the **visitor's**
  browser and device, never of the `.f3d` file — a scene cannot
  require it, and no scene line can turn it on or off.


### 8.4 XR (C4)

Like WebGL2, XR has **no `.f3d` form**: the same scene file is
the whole input. A minimal example is any scene at all — for
instance the §8.1 checker cube, unchanged.

**Semantics, in plain language.** XR support lives in a second
sidecar, `runtime/f3d-xr.js`. It exposes the generated viewer
as a **WebXR `immersive-vr`** surface: on a browser and device
that support WebXR, the viewer can offer an immersive session
for the scene it is already showing. Support is checked by
**detection** before anything is offered, exactly as in §8.3.

**Limits and honesty notes.**

- **XR needs a real device.** An immersive session needs a
  WebXR-capable headset (or equivalent device) and a browser
  that implements WebXR. Neither exists in a headless build
  environment, so the immersive path itself **cannot be
  verified headlessly** — what can be, and is, checked without
  hardware is the detection and fallback behaviour below. Any
  claim beyond that boundary would be unproven, and this
  chapter does not make one.
- **Degradation is graceful.** Where WebXR, a headset, or the
  `immersive-vr` session type is unavailable, the viewer says
  so — an "XR not available" outcome — and keeps working as an
  ordinary flat viewer (§5, §8.3). Nothing about the scene,
  the render, or the non-XR viewer changes, and no scene can
  require XR.
