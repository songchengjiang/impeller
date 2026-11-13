#include "impeller2d/engine.hpp"

#include "core/scene_catalog.h"
#include "platform/apple/design_resources.h"
#include "platform/apple/observed_backend.h"
#include "platform/apple/resource_root.h"
#include "sprite_decode.h"

#include <algorithm>
#include <array>
#include <utility>

namespace {

namespace i2d = impeller2d;

i2d::Color ColorFromARGB(uint32_t argb) {
  return {float((argb >> 16) & 255) / 255, float((argb >> 8) & 255) / 255, float(argb & 255) / 255,
          float(argb >> 24) / 255};
}

i2d::Paint PaintFromARGB(uint32_t argb) { return {.color = ColorFromARGB(argb)}; }

void Stroke(i2d::Paint& paint, float width) {
  paint.style = i2d::DrawStyle::Stroke;
  paint.stroke_width = width;
  paint.join = i2d::StrokeJoin::Bevel;
}

i2d::Path MakePath(const std::vector<cm::PathCommand>& commands) {
  i2d::Path path;
  for (const auto& command : commands) {
    const i2d::Point end{command.x, command.y};
    const i2d::Point control{command.cx, command.cy};
    switch (command.verb) {
      case 'M':
        path.moveTo(end);
        break;
      case 'L':
        path.lineTo(end);
        break;
      case 'Q':
        path.quadraticTo(control, end);
        break;
      case 'C':
        path.cubicTo(control, {command.dx, command.dy}, end);
        break;
      case 'Z':
        path.close();
        break;
      case 'E':
        path.addOval({end.x - control.x, end.y - control.x, 2 * control.x, 2 * control.x});
        break;
      default:
        throw std::runtime_error("unsupported Impeller2D path verb");
    }
  }
  return path;
}

template <size_t N>
i2d::ColorSource Gradient(const std::array<float, 4>& line, const std::array<uint32_t, N>& colors,
                          const std::array<float, N>& offsets) {
  std::array<i2d::GradientStop, N> stops;
  for (size_t i = 0; i < N; ++i) {
    stops[i] = {offsets[i], ColorFromARGB(colors[i])};
  }
  return i2d::ColorSource::linear({line[0], line[1]}, {line[2], line[3]}, stops);
}

void DrawPaths(i2d::Canvas& canvas, const cm::Frame& frame) {
  for (const auto& path : frame.paths) {
    const bool state = path.clip || path.local_gradient || path.tx != 0 || path.ty != 0 ||
                       path.rotation != 0 || path.scale != 1;
    if (state) {
      canvas.save();
    }
    if (path.tx != 0 || path.ty != 0) {
      canvas.translate(path.tx, path.ty);
    }
    if (path.rotation != 0) {
      canvas.rotate(path.rotation);
    }
    if (path.scale != 1) {
      canvas.scale(path.scale, path.scale);
    }
    if (path.local_gradient) {
      canvas.translate(-.5f, -.5f);
    }
    auto paint = PaintFromARGB(path.color);
    if (path.stroke) {
      Stroke(paint, path.width);
    }
    if (path.square_cap) {
      paint.cap = i2d::StrokeCap::Square;
    }
    if (path.gradient) {
      paint.source = Gradient(frame.gradient_points, frame.gradient_colors, frame.gradient_stops);
    }
    if (path.local_gradient) {
      paint.source = Gradient(path.gradient_line, path.colors, std::array{0.0f, 1.0f});
    }
    if (path.stroke && !path.clip && path.commands.size() == 2 && path.commands[0].verb == 'M' &&
        path.commands[1].verb == 'L') {
      canvas.drawLine({path.commands[0].x, path.commands[0].y},
                      {path.commands[1].x, path.commands[1].y}, paint);
    } else {
      auto native = MakePath(path.commands);
      if (path.clip) {
        canvas.clipPath(native, i2d::ClipOp::Intersect, false);
        canvas.drawRect({0, 0, 1, 1}, paint);
      } else {
        canvas.drawPath(native, paint);
      }
    }
    if (state) {
      canvas.restore();
    }
  }
}

void DrawSprites(i2d::Canvas& canvas, const cm::Frame& frame,
                 const std::vector<i2d::Image>& images) {
  for (const auto& sprite : frame.sprites) {
    canvas.save();
    const float half_size = sprite.size / 2;
    canvas.translate(sprite.x + half_size, sprite.y + half_size);
    canvas.rotate(sprite.rotation);
    i2d::Paint paint{.color = {1, 1, 1, sprite.opacity}};
    canvas.drawImage(images.at(sprite.image), {0, 0, 100, 100},
                     {-half_size, -half_size, sprite.size, sprite.size}, i2d::Sampling::Linear,
                     &paint);
    canvas.restore();
  }
}

class Impeller2DBackend final : public ObservedMetalBackend {
 public:
  using ObservedMetalBackend::ObservedMetalBackend;

  void Prepare(id<MTLTexture> texture) override {
    require(options.samples == 4, "Impeller2D uses 4x MSAA targets");
    renderer = i2d::MetalRenderer::create((__bridge void*)device, (__bridge void*)observed);
    require(bool(renderer), "Impeller2D context creation failed");
    Bind(texture);
    if (options.scene == "leaves") {
      constexpr const char* names[] = {
          "compass", "console",   "contribute", "debugger", "inspector", "layout",  "performance",
          "script",  "shortcuts", "standards",  "storage",  "styles",    "timeline"};
      for (auto name : names) {
        auto bgra =
            decode_sprite([NSString stringWithFormat:@"%s/third_party/motionmark-scenes/%s100.png",
                                                     cm_resource_root(), name]);
        for (size_t i = 0; i < bgra.size(); i += 4) {
          std::swap(bgra[i], bgra[i + 2]);
        }
        auto image = renderer->createImage({100, 100}, bgra);
        require(bool(image), "Impeller2D image upload failed");
        images.push_back(std::move(image));
      }
    }
    if (options.scene == "design") {
      AppleDesignResources prepared(cm_resource_root());
      font_metadata = prepared.fonts;
      glyph_input = prepared.glyph_input;
      for (auto ct : prepared.faces) {
        auto font = i2d::Font::fromCoreText(ct);
        require(bool(font), "Impeller2D font bridge failed");
        fonts.push_back(std::move(font));
      }
      text = std::move(prepared.text);
    }
    WaitIdle();
    [observed.buffers removeAllObjects];
  }

  void Bind(id<MTLTexture> texture) override { target = texture; }
  void ReleaseTarget() override { target = nil; }

  void Draw(const cm::Frame& frame) override {
    require(target != nil, "Impeller2D render target is missing");
    i2d::Canvas canvas;
    canvas.clear(ColorFromARGB(frame.background));
    if (frame.is_arcs) {
      for (const auto& arc : frame.arcs) {
        auto paint =
            PaintFromARGB(0xff000000u | uint32_t(arc.r) << 16 | uint32_t(arc.g) << 8 | arc.b);
        if (arc.stroke) {
          Stroke(paint, arc.line_width);
        }
        canvas.drawArc({arc.x - arc.radius, arc.y - arc.radius, 2 * arc.radius, 2 * arc.radius},
                       arc.start, arc.sweep, !arc.stroke, paint);
      }
    } else if (!frame.sprites.empty()) {
      DrawSprites(canvas, frame, images);
    } else if (!frame.text.empty()) {
      for (const auto& layer : frame.text) {
        for (const auto& run : text.runs) {
          std::vector<i2d::Point> positions(run.glyphs.size());
          for (size_t i = 0; i < positions.size(); ++i) {
            positions[i] = {run.x[i], run.y[i]};
          }
          require(canvas.drawGlyphs(fonts.at(run.face), run.glyphs, positions, {layer.x, layer.y},
                                    PaintFromARGB(layer.color)),
                  "Impeller2D glyph recording failed");
        }
      }
    } else if (!frame.paths.empty()) {
      DrawPaths(canvas, frame);
    }
    require(renderer->render((__bridge void*)target, canvas.finish()) == i2d::RenderResult::Success,
            "Impeller2D render failed");
  }

  NSDictionary* Metadata() const override {
    return @{
      @"fonts" : font_metadata,
      @"glyph_input" : glyph_input,
      @"impeller_local_extension" : @"impeller2d-cpp"
    };
  }

 private:
  std::unique_ptr<i2d::MetalRenderer> renderer;
  id<MTLTexture> target = nil;
  std::vector<i2d::Image> images;
  std::vector<i2d::Font> fonts;
  cm::DesignText text;
  NSMutableArray* font_metadata = [NSMutableArray new];
  NSMutableArray* glyph_input = [NSMutableArray new];
};

}  // namespace

cm::BackendDescription DescribeBackend() {
  auto scenes = cm::ImplementedScenes();
  scenes.erase(std::remove(scenes.begin(), scenes.end(), "validation-rects"), scenes.end());
  scenes.erase(std::remove(scenes.begin(), scenes.end(), "images-roundtrip"), scenes.end());
  auto operations = cm::FullMetalOperations();
  operations.pop_back();  // pixel-roundtrip
  return {"impeller",
          "impeller-metal",
          cm_apple_platform(),
          "surface-msaa",
          "create-per-frame",
          "none",
          std::move(scenes),
          true,
          4,
          std::move(operations)};
}

std::unique_ptr<MetalBackend> MakeBackend(const cm::BackendOptions& options) {
  return std::make_unique<Impeller2DBackend>(options);
}
