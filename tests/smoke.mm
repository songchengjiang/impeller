#import <Metal/Metal.h>

#include <algorithm>
#include <array>
#include <cstdio>
#include <cstdlib>

#include "impeller2d/engine.hpp"

using namespace impeller2d;

namespace {

void Require(bool ok, const char* message) {
  if (!ok) {
    std::fprintf(stderr, "%s\n", message);
    std::exit(1);
  }
}

using Pixel = std::array<uint8_t, 4>;

Pixel At(const Bitmap& bitmap, int x, int y) {
  Pixel pixel;
  const auto offset = (y * bitmap.size.width + x) * 4;
  std::copy_n(bitmap.pixels.begin() + offset, pixel.size(), pixel.begin());
  return pixel;
}

void Expect(const Bitmap& bitmap, int x, int y, Pixel expected) {
  const auto actual = At(bitmap, x, y);
  for (size_t channel = 0; channel < actual.size(); ++channel) {
    if (std::abs(static_cast<int>(actual[channel]) - expected[channel]) > 3) {
      std::fprintf(stderr, "Pixel (%d, %d) is (%u, %u, %u, %u), expected (%u, %u, %u, %u)\n", x, y,
                   actual[0], actual[1], actual[2], actual[3], expected[0], expected[1],
                   expected[2], expected[3]);
      std::exit(1);
    }
  }
}

}  // namespace

int main() {
  @autoreleasepool {
    id<MTLDevice> device = MTLCreateSystemDefaultDevice();
    Require(device != nil, "Metal device unavailable");
    id<MTLCommandQueue> queue = [device newCommandQueue];
    auto renderer = MetalRenderer::create((__bridge void*)device, (__bridge void*)queue);
    Require(renderer && renderer->device() == (__bridge void*)device,
            "Metal renderer creation failed");

    Canvas canvas({0, 0, 96, 96});
    canvas.clear({0, 0, 1, 1});
    canvas.save();
    canvas.translate(8, 8);
    Path clip;
    clip.addRect({0, 0, 16, 16});
    canvas.clipPath(clip);
    canvas.drawRect({0, 0, 32, 32}, {.color = {1, 0, 0, 1}});
    canvas.restore();

    const std::array pixels = {uint8_t{0}, uint8_t{255}, uint8_t{0}, uint8_t{255}};
    const auto image = renderer->createImage({1, 1}, pixels);
    Require(static_cast<bool>(image), "RGBA upload failed");
    Require(!renderer->createImage({2, 1}, pixels), "Short image accepted");
    canvas.drawImage(image, {0, 0, 1, 1}, {48, 4, 8, 8}, Sampling::Nearest);

    // A 1x2 PNG with a magenta top row and a cyan bottom row.
    const uint8_t png[] = {137, 80,  78,  71, 13, 10, 26,  10, 0,  0,  0,   13,  73,  72,  68,
                           82,  0,   0,   0,  1,  0,  0,   0,  2,  8,  6,   0,   0,   0,   153,
                           129, 182, 39,  0,  0,  0,  17,  73, 68, 65, 84,  120, 156, 99,  248,
                           207, 240, 255, 63, 3,  16, 255, 7,  0,  27, 238, 5,   251, 163, 78,
                           114, 150, 0,   0,  0,  0,  73,  69, 78, 68, 174, 66,  96,  130};
    auto decoded = renderer->decodeImage(png);
    Require(decoded && decoded.size().width == 1 && decoded.size().height == 2,
            "PNG decode failed");
    canvas.drawImage(decoded, {0, 0, 1, 2}, {58, 4, 8, 16}, Sampling::Nearest);
    Require(!renderer->decodeImage(pixels), "Invalid image data accepted");

    const std::array triangle = {impeller2d::Point{50, 26}, impeller2d::Point{66, 26},
                                 impeller2d::Point{50, 42}};
    canvas.drawVertices(VertexMode::Triangles, triangle, {}, {}, BlendMode::Source,
                        {.color = {1, 0, 0, 1}});

    const std::array stops = {
        GradientStop{0, {1, 0, 0, 1}},
        GradientStop{1, {0, 1, 0, 1}},
    };
    Paint gradient;
    gradient.source = ColorSource::linear({8, 0}, {40, 0}, stops);
    canvas.drawRect({8, 32, 32, 8}, gradient);

    Paint blur;
    blur.color = {1, 1, 1, 1};
    blur.filter = ImageFilter::blur(2, 2);
    canvas.drawOval({73, 8, 12, 12}, blur);

    const std::array text = {TextRun{"Hi 中文", {.size = 18, .color = {1, 1, 1, 1}}}};
    auto paragraph = renderer->layoutText(text, 88);
    Require(paragraph && paragraph.height() > 0 && paragraph.longestLine() > 0,
            "Text layout failed");
    canvas.drawParagraph(paragraph, {4, 48});
    const auto list = canvas.finish();

    auto bitmap = renderer->rasterize({96, 96}, list);
    Require(bitmap && bitmap->pixels.size() == 96 * 96 * 4, "GPU readback failed");
    Expect(*bitmap, 0, 0, {0, 0, 255, 255});
    Expect(*bitmap, 16, 16, {255, 0, 0, 255});
    Expect(*bitmap, 25, 16, {0, 0, 255, 255});
    Expect(*bitmap, 51, 7, {0, 255, 0, 255});
    Expect(*bitmap, 61, 7, {255, 0, 255, 255});
    Expect(*bitmap, 61, 17, {0, 255, 255, 255});
    Expect(*bitmap, 52, 28, {255, 0, 0, 255});
    Require(At(*bitmap, 10, 36)[0] > 200 && At(*bitmap, 38, 36)[1] > 200,
            "Gradient was not rendered");
    const auto blur_pixel = At(*bitmap, 72, 14);
    Require(blur_pixel[0] > 10 && blur_pixel[0] < 200, "Blur edge was not rendered");
    int glyph_pixels = 0;
    for (int y = 48; y < 80; ++y) {
      for (int x = 4; x < 92; ++x) {
        glyph_pixels += At(*bitmap, x, y)[0] > 200;
      }
    }
    Require(glyph_pixels > 25, "Text was not rendered into the glyph atlas");

    auto replay = renderer->rasterize({96, 96}, list);
    Require(replay && replay->pixels == bitmap->pixels, "Replay changed pixels");
    Require(!renderer->rasterize({0, 96}, list), "Invalid bitmap size accepted");
    Require(renderer->render(nullptr, list) == RenderResult::InvalidTarget,
            "Null Metal target accepted");

    auto descriptor =
        [MTLTextureDescriptor texture2DDescriptorWithPixelFormat:MTLPixelFormatBGRA8Unorm
                                                           width:96
                                                          height:96
                                                       mipmapped:NO];
    descriptor.usage = MTLTextureUsageRenderTarget | MTLTextureUsageShaderRead;
    id<MTLTexture> target = [device newTextureWithDescriptor:descriptor];
    Require(renderer->render((__bridge void*)target, list) == RenderResult::Success,
            "Host-owned texture rendering failed");
    auto wrapped = renderer->wrapTexture((__bridge void*)target);
    Require(static_cast<bool>(wrapped), "Host-owned texture wrapping failed");
    canvas.drawImage(wrapped, {0, 0, 96, 96}, {0, 0, 96, 96}, Sampling::Nearest);
    auto wrapped_bitmap = renderer->rasterize({96, 96}, canvas.finish());
    Require(wrapped_bitmap.has_value(), "Sampling a host-owned texture failed");
    Expect(*wrapped_bitmap, 16, 16, {255, 0, 0, 255});
    Expect(*wrapped_bitmap, 51, 7, {0, 255, 0, 255});
    Require(renderer->waitUntilIdle(), "Metal synchronization failed");

    auto other = MetalRenderer::create();
    Require(other && !other->rasterize({96, 96}, list),
            "Display list accepted on the wrong renderer");
    canvas.clear({1, 1, 0, 1});
    auto reset = other->rasterize({96, 96}, canvas.finish());
    Require(reset.has_value(), "Canvas retained image ownership after finish");
    Expect(*reset, 12, 12, {255, 255, 0, 255});
    std::puts("Impeller2D Metal smoke test passed.");
  }
}
