# Fortran 3D Engine

A modular 3D software rendering engine written in modern Fortran (Fortran 2008/2018).

## Directory Structure

```
3d_engine/
├── assets/          # Static assets (3D models, textures, shaders)
│   ├── models/
│   ├── shaders/
│   └── textures/
├── bin/             # Compiled binaries
├── docs/            # Architecture and documentation
├── include/         # Fortran module interface files (.mod)
├── lib/             # External libraries / bindings
├── obj/             # Compiled object files (.o)
├── src/             # Source code
│   ├── math_3d.f90  # Vector3, Matrix4x4, transforms, projections
│   ├── mesh.f90     # Triangle and Mesh structures, primitives (cube)
│   ├── camera.f90   # Camera, LookAt view matrix, perspective projection
│   ├── renderer.f90 # Framebuffer, Z-buffer, software rasterizer, PPM export
│   └── main.f90     # Entry point and demo scene
├── tests/           # Unit and regression tests
└── Makefile         # Build configuration
```

## Features

- **Linear Algebra Math Library**: Vectors (`vec3`), 4x4 Matrices (`mat4`), dot/cross products, normalization, transformation, rotation, look-at, and perspective projection.
- **Mesh Representation**: Triangle lists with vertex normals and face colors.
- **Camera System**: Full 3D camera with adjustable FOV, near/far clipping planes, aspect ratio, position, and target.
- **Software Rasterizer**: Barycentric triangle rasterization, depth buffering (Z-buffer), and directional Lambertian shading.
- **Image Exporter**: Generates `.ppm` image files which can be viewed in standard image viewers or converted to PNG/JPG.

## Quick Start

### Build and Run

```bash
cd 3d_engine
make run
```

### View Rendered Output

The engine outputs `output_render.ppm`. You can convert it to PNG or view it directly:

```bash
# Convert to PNG using ImageMagick (if installed)
convert output_render.ppm output_render.png
```
