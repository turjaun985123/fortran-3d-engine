/**
 * f3d.d.ts — TypeScript declarations for the Forge3D browser runtime.
 *
 * Describes the global published by runtime/f3d.js (seat B28):
 * `window.F3D`, also available as the bare global `F3D`.
 * Scene field shapes follow the f3dc IR contract (ir_version 1).
 */

/** A 3-component tuple: `[x, y, z]`, or `[r, g, b]` for colours. */
declare type F3DVec3 = [number, number, number];

declare interface F3DCamera {
  pos: F3DVec3;
  target: F3DVec3;
  up: F3DVec3;
  fov: number;
  near: number;
  far: number;
}

declare interface F3DLight {
  kind: string;
  direction: F3DVec3;
  color: F3DVec3;
  intensity: number;
}

declare interface F3DObject {
  name: string;
  prim: string;
  color: F3DVec3 | null;
  pos: F3DVec3;
  rotate: F3DVec3;
  scale: F3DVec3;
  size: number | null;
  radius: number | null;
  height: number | null;
  segments: number | null;
  material: string;
}

declare interface F3DAnim {
  kind: string;
  target: string;
  axis: string;
  speed: number;
  duration: number;
  fps: number;
  ease: string;
  loop: string;
}

declare interface F3DScene {
  name: string;
  width: number;
  height: number;
  bg: F3DVec3;
  camera: F3DCamera;
  lights: F3DLight[];
  objects: F3DObject[];
  animations: F3DAnim[];
  outputs: unknown[];
}

declare interface F3DPlayer {
  play(): void;
  pause(): void;
  setTime(t: number): void;
  render(t?: number): void;
  destroy(): void;
}

/** The runtime API exposed as `window.F3D` / the global `F3D`. */
declare interface F3DRuntime {
  readonly version: string;
  create(
    target: HTMLCanvasElement | HTMLElement,
    scene: F3DScene
  ): F3DPlayer;
  auto(scene: F3DScene): F3DPlayer | null;
}

/** The `<f3d-view>` custom element. */
declare interface F3DViewElement extends HTMLElement {
  player: F3DPlayer | null;
  scene: F3DScene | null;
}

declare const F3D: F3DRuntime;

interface Window {
  F3D: F3DRuntime;
}

interface HTMLElementTagNameMap {
  "f3d-view": F3DViewElement;
}
