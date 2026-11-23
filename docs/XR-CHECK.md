# Forge3D XR device check (parity item C4)

Forge3D's WebXR support (`runtime/f3d-xr.js`) is verified headlessly
with mocked WebXR objects, but an immersive session cannot be
verified without real hardware. This kit is the 5-minute manual
check that closes the last open parity item. **The check has NOT
been run yet** — preparing this kit does not change C4's status.

## What you need

- An XR-capable device and browser:
  - an Android phone with Chrome (WebXR + AR/VR support), or
  - a standalone headset browser (e.g. Meta Quest Browser), or
  - a PC VR headset with a WebXR-capable browser.
- The file `examples/xr-check.html` from this repo. It is a single
  self-contained page (scene, viewer, WebXR sidecar and the
  "Enter VR" glue are all inlined — no server or other files
  needed). WebXR requires a secure context, so serve it over
  `https://` or `http://localhost` if the browser refuses to offer
  XR from a plain `file://` page; the flat viewer works either way.

## Steps

1. Open `examples/xr-check.html` on the device.
2. The flat viewer should already be animating: a red spinning
   cube (left), a blue bobbing sphere (centre) and a green pulsing
   pyramid (right). Below it, a status box reports whether WebXR
   `immersive-vr` is available.
   - If the status says XR is **not** available, the device/browser
     cannot run this check — the flat viewer animating is the
     graceful fallback working as designed, but C4 stays open.
     Try Chrome on an XR-capable Android phone or a headset
     browser.
3. If the **Enter VR** button is enabled, press it and put the
   headset on (or hold the phone up).
4. Look around for ~30 seconds, then exit the session (headset
   button / back gesture).

## What success looks like

- The three primitives appear in front of you, in stereo, at
  roughly eye height.
- The scene **tracks your head movement**: turning or moving your
  head moves the view naturally, with no lag spikes or judder
  beyond the device's norm.
- The animations keep running in XR: the cube spins, the sphere
  bobs, the pyramid pulses.
- No black screen, no frozen frame, no error text in the page's
  status line after you exit.

## What to report back

One line is enough: the device + browser you used, and either
"XR check passed — scene rendered immersively and tracked head
movement" or a short description of what went wrong (what the
status line said, black screen, no tracking, session refused…).

A successful run flips parity item **C4** to Done in
`docs/parity-status.json` — the last open item, taking Forge3D to
**40/40**. Until then C4 stays honestly marked open/blocked.
