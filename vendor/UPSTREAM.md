# Upstream sources

The source snapshot is from Flutter commit
[`6e79542b39c1859158abf6f288c963bf0f855aab`](https://github.com/flutter/flutter/tree/6e79542b39c1859158abf6f288c963bf0f855aab/engine/src/flutter).
The CMake source list follows the upstream runtime targets for Impeller, Display
List, FML, and txt. It includes the Metal renderer and Skia typography backend.
The upstream BSD license is in [LICENSE](LICENSE). The C++ interface in
`include/impeller2d` and its implementation are part of this project.

Changes to the extracted sources include local include paths, an
`impeller_dl` namespace for Display List, standalone trace event types, and
removal of the Flutter drawable presentation hook. Render-pass completion now
returns an error to the embedding interface if encoding or submission fails.

`generated/impeller` contains the shader reflection and Metal libraries
generated from this snapshot's GLSL, using the matching `impellerc` and Apple's
Metal toolchain. The library embeds these at build time.

The bootstrap script pins Skia and FlatBuffers source commits and checks the
archives against SHA-256 hashes. Skia supplies paths, font access, shaping
integration, and glyph rasterization. HarfBuzz and ICU supply shaping and Unicode
services. Abseil supplies C++ containers and utility types. Their respective
licenses accompany those distributions.
