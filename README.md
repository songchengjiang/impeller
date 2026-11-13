# Impeller2D

Impeller 的独立 C++20 渲染库。当前构建目标为 Apple Silicon macOS，后端为 Metal。宿主可以直接链接 `Impeller2D::impeller2d`，录制可重放的绘制命令并渲染到自己的 drawable 或纹理。

项目从上游 [`6e79542b39c1859158abf6f288c963bf0f855aab`](https://github.com/flutter/flutter/tree/6e79542b39c1859158abf6f288c963bf0f855aab/engine/src/flutter/impeller) 提取了 Impeller、Display List、FML 和排版组件。构建使用本项目的 CMake，应用运行时只链接本项目库、图形和文本第三方库及 macOS 系统框架。公开接口为 [`impeller2d/engine.hpp`](include/impeller2d/engine.hpp)。

## 构建并运行

已验证 Apple Silicon 上的 macOS 26。准备 Xcode、CMake 3.25+、Ninja、Python 3.12+，以及本机的 ICU、HarfBuzz 和 Abseil。

```sh
brew install cmake ninja pkgconf python@3.13 icu4c harfbuzz abseil
"$(brew --prefix python@3.13)/libexec/bin/python3" scripts/bootstrap_macos.py
cmake -S . -B build -G Ninja -DCMAKE_BUILD_TYPE=Release
cmake --build build --parallel
./build/impeller2d_demo
ctest --test-dir build --output-on-failure
```

首次准备依赖会下载并编译固定版本的 Skia 和 FlatBuffers，并使用 Skia 的脚本获取 GN。已有 GN 可传给 `bootstrap_macos.py --gn /path/to/gn`。默认构建使用项目中的 Metal shader 和 C++ 反射文件。完整清单见 [上游源码与许可证](vendor/UPSTREAM.md)。

`impeller2d_demo --once` 提交一帧并关闭窗口。测试使用真实 Metal GPU 并读回像素。若在无法访问 Metal 的沙箱里运行，请在宿主终端运行测试。

## 集成到 C++ 框架

可以通过 `add_subdirectory` 使用源码，也可以安装 CMake 包。

```sh
cmake --install build --prefix "$PWD/build/sdk"
```

```cmake
find_package(Impeller2D CONFIG REQUIRED)
target_link_libraries(my_framework PRIVATE Impeller2D::impeller2d)
```

配置宿主时，用 `CMAKE_PREFIX_PATH` 指向安装目录。部署动态库时需提供其链接的 ICU、HarfBuzz、Abseil 动态库及它们的依赖，或者在目标环境以相应依赖重新构建。公开接口使用 C++ 标准库类型，请用兼容的 C++20 工具链和 libc++ 构建宿主。

```cpp
#include <impeller2d/engine.hpp>

auto renderer = impeller2d::MetalRenderer::create();
if (!renderer) {
  return 1;
}

impeller2d::Canvas canvas({0, 0, 320, 240});
canvas.clear({0.06f, 0.08f, 0.12f, 1});
canvas.drawRoundRect({24, 24, 100, 80}, 12, 12,
                     {.color = {0.15f, 0.7f, 0.85f, 1}});
const auto picture = canvas.finish();
auto bitmap = renderer->rasterize({320, 240}, picture);
```

- **窗口**。在 Objective-C++ 平台适配层，将宿主 `MTLDevice` 和可选的 `MTLCommandQueue` 通过 `__bridge void*` 交给 `MetalRenderer::create`。用同一设备配置 `CAMetalLayer`，设置 `framebufferOnly = NO`，并在 resize 或 Retina 比例变化时更新 `drawableSize`。每帧获取 drawable，调用 `present`。宿主管理窗口、调度和帧循环。
- **宿主纹理**。调用 `render`，目标为同一设备上的单采样 2D `BGRA8Unorm` 或 `RGBA8Unorm` 纹理，同时启用 `RenderTarget` 和 `ShaderRead`。下游 GPU 操作可在同一队列继续提交。跨队列或 CPU 读取前调用 `waitUntilIdle`，或者由宿主管理 GPU 同步。用 `wrapTexture` 可将兼容的宿主纹理零拷贝用作 Canvas 图像。采样时应确保源纹理已写入，并与当前渲染目标使用不同的纹理。
- **录制与资源**。`finish` 返回可重放的 Display List 并重置 Canvas。绘制坐标以左上角为原点，直接提交到目标时单位是像素。宿主可用 Canvas 缩放映射逻辑坐标。每个 renderer 的渲染、资源和排版操作串行调用。包含图像的录制应交回创建图像的 renderer。
- **绘制与文字**。支持路径、形状、描边、顶点、阴影、裁剪、变换、图层、混合、渐变、滤镜、图像解码和上传，以及 UTF-8 多样式段落排版。可以从字节注册自定义字体。离屏输出为自顶向下、紧密排列的预乘 RGBA8。
- **平台范围**。项目目前提供 macOS/Metal 后端。窗口示例使用 AppKit，公共头文件可以由普通 C++ 编译。Vulkan、OpenGL ES、移动平台和自定义运行时着色器的公开接口尚未接入。

## 修改 GLSL 后重新生成 Metal shader

默认构建直接编译渲染器源码并嵌入已生成的 shader。修改 `vendor/impeller` 下的 GLSL 时，可启用重新生成流程。此流程需要 Apple Metal Toolchain，以及与当前源码版本匹配的 `impellerc`。依赖脚本的 `--shader-tools` 选项从上游发布包中提取编译器。也可以用 `-DIMPELLER2D_IMPELLERC=/path/to/impellerc` 提供自己的编译器。

```sh
xcodebuild -downloadComponent MetalToolchain
"$(brew --prefix python@3.13)/libexec/bin/python3" scripts/bootstrap_macos.py --shader-tools
cmake -S . -B build-shaders -G Ninja -DCMAKE_BUILD_TYPE=Release \
  -DIMPELLER2D_REBUILD_SHADERS=ON
cmake --build build-shaders --parallel
```

生成文件位于 `build-shaders/generated/impeller`。更新项目自带的 shader 时，将对应的 `*.metallib` 和反射 `*.h`、`*.cc` 一起同步到 `vendor/generated/impeller`。
