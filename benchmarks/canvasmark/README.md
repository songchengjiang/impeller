# CanvasMark · Impeller2D

以 CanvasMark `bf0e4f894ca19df0407f88afd7fb9fa08071cbe2` 为基准，使用工作区的独立 Impeller2D C++ 动态库跑 macOS 窗口测试。适配保留 CanvasMark 的场景生成、输入资源、Design 预排版字形、逐帧采样、负载控制及评分脚本。

## 复现

先按[项目说明](../../README.md)构建 Impeller2D，再在一份干净的 CanvasMark 工作区准备依赖和适配器。

```sh
impeller_root=/absolute/path/to/impeller
cmake --install "$impeller_root/build-clean" --prefix "$impeller_root/build-clean/sdk"

git apply "$impeller_root/benchmarks/canvasmark/canvasmark.patch"
cp "$impeller_root/benchmarks/canvasmark/impeller2d_metal.mm" src/backends/
python3 -B tools/prepare_text.py
cmake -S . -B build-macos/impeller-metal -G Ninja -DCMAKE_BUILD_TYPE=Release \
  -DCM_BACKENDS=impeller -DIMPELLER2D_SDK="$impeller_root/build-clean/sdk"
cmake --build build-macos/impeller-metal --target canvasmark_impeller --parallel
```

在 60 Hz 显示器上运行。可把 `CANVASMARK_SCREEN_NAME` 设为目标屏幕的 macOS 名称，或省略它使用主屏幕。输出目录应为新目录。

```sh
CANVASMARK_SCREEN_NAME='DELL U2723QE' caffeinate -d -i python3 -B tools/suite.py run \
  --engines impeller --seconds 30 --rounds 3 --skip-correctness \
  --output results/impeller2d
```

`suite.json` 汇总各轮分数、构建身份和数据文件的哈希。`stdout.json` 保存逐帧回调与复杂度，`scored.json` 保存离线评分和单轮区间。完整七场景的像素正确性在 CanvasMark 中标为 `unchecked`。Leaves 使用 Impeller2D 公开接口的严格源矩形采样，输入仍为完整的原始 100×100 PNG。
