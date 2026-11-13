#include "impeller2d/engine.hpp"

#import <CoreText/CoreText.h>
#import <ImageIO/ImageIO.h>
#import <Metal/Metal.h>
#import <QuartzCore/CAMetalLayer.h>

#include <algorithm>
#include <cmath>
#include <limits>
#include <stdexcept>
#include <utility>

#include "display_list/dl_builder.h"
#include "display_list/dl_vertices.h"
#include "display_list/geometry/dl_path_builder.h"
#include "fml/mapping.h"
#include "fml/platform/darwin/cf_utils.h"
#include "fml/synchronization/sync_switch.h"
#include "impeller/display_list/aiks_context.h"
#include "impeller/display_list/dl_dispatcher.h"
#include "impeller/display_list/dl_image_impeller.h"
#include "impeller/display_list/dl_text_impeller.h"
#include "impeller/entity/mtl/entity_shaders.h"
#include "impeller/entity/mtl/framebuffer_blend_shaders.h"
#include "impeller/entity/mtl/modern_shaders.h"
#include "impeller/renderer/backend/metal/context_mtl.h"
#include "impeller/renderer/backend/metal/formats_mtl.h"
#include "impeller/renderer/backend/metal/surface_mtl.h"
#include "impeller/renderer/backend/metal/texture_mtl.h"
#include "impeller/renderer/mtl/compute_shaders.h"
#include "impeller/typographer/backends/skia/typographer_context_skia.h"
#include "include/core/SkData.h"
#include "include/core/SkFont.h"
#include "include/core/SkTextBlob.h"
#include "include/ports/SkTypeface_mac.h"
#include "txt/paragraph_builder.h"
#include "txt/platform.h"

namespace impeller2d {
namespace {

using namespace impeller_dl;

DlRect ToRect(Rect rect) { return DlRect::MakeXYWH(rect.x, rect.y, rect.width, rect.height); }

DlPoint ToPoint(Point point) { return {point.x, point.y}; }

DlColor ToColor(Color color) {
  return DlColor::RGBA(color.red, color.green, color.blue, color.alpha);
}

DlTileMode ToTile(TileMode tile) {
  switch (tile) {
    case TileMode::Clamp:
      return DlTileMode::kClamp;
    case TileMode::Repeat:
      return DlTileMode::kRepeat;
    case TileMode::Mirror:
      return DlTileMode::kMirror;
    case TileMode::Decal:
      return DlTileMode::kDecal;
  }
  return DlTileMode::kClamp;
}

DlClipOp ToClip(ClipOp op) {
  return op == ClipOp::Difference ? DlClipOp::kDifference : DlClipOp::kIntersect;
}

struct GradientData {
  std::vector<DlColor> colors;
  std::vector<float> offsets;

  explicit GradientData(std::span<const GradientStop> stops) {
    if (stops.size() < 2 || stops.size() > std::numeric_limits<uint32_t>::max()) {
      throw std::invalid_argument("A gradient requires at least two stops");
    }
    colors.reserve(stops.size());
    offsets.reserve(stops.size());
    float previous = 0;
    for (const auto& stop : stops) {
      if (!std::isfinite(stop.offset) || stop.offset < previous || stop.offset > 1) {
        throw std::invalid_argument("Gradient stops must be ordered within [0, 1]");
      }
      previous = stop.offset;
      offsets.push_back(stop.offset);
      colors.push_back(ToColor(stop.color));
    }
  }
};

std::vector<std::shared_ptr<fml::Mapping>> ShaderLibraries() {
  using fml::NonOwnedMapping;
  return {
      std::make_shared<NonOwnedMapping>(impeller_entity_shaders_data,
                                        impeller_entity_shaders_length),
      std::make_shared<NonOwnedMapping>(impeller_modern_shaders_data,
                                        impeller_modern_shaders_length),
      std::make_shared<NonOwnedMapping>(impeller_framebuffer_blend_shaders_data,
                                        impeller_framebuffer_blend_shaders_length),
      std::make_shared<NonOwnedMapping>(impeller_compute_shaders_data,
                                        impeller_compute_shaders_length),
  };
}

std::optional<size_t> ByteCount(Size size) {
  if (size.width <= 0 || size.height <= 0) {
    return std::nullopt;
  }
  auto row = static_cast<size_t>(size.width) * 4;
  auto height = static_cast<size_t>(size.height);
  if (height > std::numeric_limits<size_t>::max() / row) {
    return std::nullopt;
  }
  return row * height;
}

}  // namespace

Path& Path::moveTo(Point point) {
  commands_.push_back({Verb::Move, point});
  return *this;
}

Path& Path::lineTo(Point point) {
  commands_.push_back({Verb::Line, point});
  return *this;
}

Path& Path::quadraticTo(Point control, Point end) {
  commands_.push_back({Verb::Quadratic, control, end});
  return *this;
}

Path& Path::cubicTo(Point first, Point second, Point end) {
  commands_.push_back({Verb::Cubic, first, second, end});
  return *this;
}

Path& Path::close() {
  commands_.push_back({Verb::Close});
  return *this;
}

Path& Path::addRect(Rect bounds) {
  commands_.push_back({.verb = Verb::Rect, .bounds = bounds});
  return *this;
}

Path& Path::addOval(Rect bounds) {
  commands_.push_back({.verb = Verb::Oval, .bounds = bounds});
  return *this;
}

Path& Path::setFillRule(FillRule rule) {
  fill_rule_ = rule;
  return *this;
}

struct ColorSource::Impl {
  std::shared_ptr<const DlColorSource> source;
};

ColorSource::ColorSource(std::shared_ptr<const Impl> impl) : impl_(std::move(impl)) {}

ColorSource ColorSource::linear(Point from, Point to, std::span<const GradientStop> stops,
                                TileMode tile) {
  const GradientData data(stops);
  return ColorSource(std::make_shared<Impl>(DlColorSource::MakeLinear(
      ToPoint(from), ToPoint(to), static_cast<uint32_t>(data.colors.size()), data.colors.data(),
      data.offsets.data(), ToTile(tile))));
}

ColorSource ColorSource::radial(Point center, float radius, std::span<const GradientStop> stops,
                                TileMode tile) {
  if (!std::isfinite(radius) || radius <= 0) {
    throw std::invalid_argument("Radial gradient radius must be positive");
  }
  const GradientData data(stops);
  return ColorSource(std::make_shared<Impl>(
      DlColorSource::MakeRadial(ToPoint(center), radius, static_cast<uint32_t>(data.colors.size()),
                                data.colors.data(), data.offsets.data(), ToTile(tile))));
}

ColorSource ColorSource::sweep(Point center, float start_degrees, float end_degrees,
                               std::span<const GradientStop> stops, TileMode tile) {
  if (!std::isfinite(start_degrees) || !std::isfinite(end_degrees) ||
      start_degrees >= end_degrees) {
    throw std::invalid_argument("Sweep gradient angles must be increasing");
  }
  const GradientData data(stops);
  return ColorSource(std::make_shared<Impl>(DlColorSource::MakeSweep(
      ToPoint(center), start_degrees, end_degrees, static_cast<uint32_t>(data.colors.size()),
      data.colors.data(), data.offsets.data(), ToTile(tile))));
}

struct ImageFilter::Impl {
  std::shared_ptr<DlImageFilter> filter;
};

ImageFilter::ImageFilter(std::shared_ptr<const Impl> impl) : impl_(std::move(impl)) {}

ImageFilter ImageFilter::blur(float sigma_x, float sigma_y, TileMode tile) {
  return ImageFilter(
      std::make_shared<Impl>(DlImageFilter::MakeBlur(sigma_x, sigma_y, ToTile(tile))));
}

ImageFilter ImageFilter::colorMatrix(const std::array<float, 20>& matrix) {
  return ImageFilter(std::make_shared<Impl>(
      DlImageFilter::MakeColorFilter(DlColorFilter::MakeMatrix(matrix.data()))));
}

ImageFilter ImageFilter::dilate(float radius_x, float radius_y) {
  return ImageFilter(std::make_shared<Impl>(DlImageFilter::MakeDilate(radius_x, radius_y)));
}

ImageFilter ImageFilter::erode(float radius_x, float radius_y) {
  return ImageFilter(std::make_shared<Impl>(DlImageFilter::MakeErode(radius_x, radius_y)));
}

ImageFilter ImageFilter::compose(const ImageFilter& outer, const ImageFilter& inner) {
  if (!outer.impl_ || !outer.impl_->filter) {
    return inner;
  }
  if (!inner.impl_ || !inner.impl_->filter) {
    return outer;
  }
  return ImageFilter(
      std::make_shared<Impl>(DlImageFilter::MakeCompose(outer.impl_->filter, inner.impl_->filter)));
}

struct DisplayList::Impl {
  sk_sp<impeller_dl::DisplayList> list;
  // Uploaded images may only be used on the renderer that created them.
  std::vector<std::shared_ptr<const void>> image_owners;
};

DisplayList::DisplayList(std::shared_ptr<const Impl> impl) : impl_(std::move(impl)) {}
DisplayList::operator bool() const noexcept { return impl_ && impl_->list; }

struct Image::Impl {
  sk_sp<DlImage> image;
  std::shared_ptr<const void> owner;
};

Image::Image(std::shared_ptr<const Impl> impl) : impl_(std::move(impl)) {}
Image::operator bool() const noexcept { return impl_ && impl_->image; }
Size Image::size() const noexcept {
  if (!*this) {
    return {};
  }
  auto size = impl_->image->GetSize();
  return {static_cast<int>(size.width), static_cast<int>(size.height)};
}

struct Font::Impl {
  SkFont font;
  int glyph_count;
};

Font::Font(std::shared_ptr<const Impl> impl) : impl_(std::move(impl)) {}

Font Font::fromCoreText(const void* value) {
  const auto ct_font = static_cast<CTFontRef>(value);
  if (!ct_font) {
    return {};
  }
  const auto size = static_cast<float>(CTFontGetSize(ct_font));
  if (!std::isfinite(size) || size <= 0) {
    return {};
  }
  auto typeface = SkMakeTypefaceFromCTFont(ct_font);
  if (!typeface) {
    return {};
  }
  SkFont font(typeface, size);
  font.setEdging(SkFont::Edging::kAntiAlias);
  font.setSubpixel(true);
  return Font(std::make_shared<Impl>(std::move(font), typeface->countGlyphs()));
}

Font::operator bool() const noexcept { return static_cast<bool>(impl_); }

struct Paragraph::Impl {
  std::unique_ptr<txt::Paragraph> paragraph;
};

Paragraph::Paragraph(std::shared_ptr<Impl> impl) : impl_(std::move(impl)) {}
Paragraph::operator bool() const noexcept { return impl_ && impl_->paragraph; }
float Paragraph::height() const { return *this ? impl_->paragraph->GetHeight() : 0; }
float Paragraph::longestLine() const { return *this ? impl_->paragraph->GetLongestLine() : 0; }

struct Canvas::Impl {
  explicit Impl(DlRect bounds) : builder(bounds) {}

  impeller_dl::DisplayListBuilder builder;
  std::vector<std::shared_ptr<const void>> image_owners;

  void rememberOwner(const std::shared_ptr<const void>& owner) {
    if (std::find(image_owners.begin(), image_owners.end(), owner) == image_owners.end()) {
      image_owners.push_back(owner);
    }
  }

  static const DlImageFilter* Filter(const ImageFilter* filter) {
    return filter && filter->impl_ ? filter->impl_->filter.get() : nullptr;
  }

  static DlPaint PaintFor(const Paint& paint) {
    DlPaint result(ToColor(paint.color));
    result.setBlendMode(static_cast<DlBlendMode>(paint.blend))
        .setDrawStyle(static_cast<DlDrawStyle>(paint.style))
        .setStrokeCap(static_cast<DlStrokeCap>(paint.cap))
        .setStrokeJoin(static_cast<DlStrokeJoin>(paint.join))
        .setStrokeWidth(paint.stroke_width)
        .setStrokeMiter(paint.miter_limit)
        .setAntiAlias(paint.antialias);
    if (paint.source && paint.source->impl_) {
      result.setColorSource(paint.source->impl_->source);
    }
    if (paint.filter) {
      result.setImageFilter(Filter(&*paint.filter));
    }
    return result;
  }

  static DlPath PathFor(const Path& path) {
    DlPathBuilder builder;
    builder.SetFillType(path.fill_rule_ == FillRule::EvenOdd ? DlPathFillType::kOdd
                                                             : DlPathFillType::kNonZero);
    for (const auto& command : path.commands_) {
      switch (command.verb) {
        case Path::Verb::Move:
          builder.MoveTo(ToPoint(command.first));
          break;
        case Path::Verb::Line:
          builder.LineTo(ToPoint(command.first));
          break;
        case Path::Verb::Quadratic:
          builder.QuadraticCurveTo(ToPoint(command.first), ToPoint(command.second));
          break;
        case Path::Verb::Cubic:
          builder.CubicCurveTo(ToPoint(command.first), ToPoint(command.second),
                               ToPoint(command.third));
          break;
        case Path::Verb::Close:
          builder.Close();
          break;
        case Path::Verb::Rect:
          builder.AddRect(ToRect(command.bounds));
          break;
        case Path::Verb::Oval:
          builder.AddOval(ToRect(command.bounds));
          break;
      }
    }
    return builder.TakePath();
  }
};

Canvas::Canvas() : impl_(std::make_unique<Impl>(DisplayListBuilder::kMaxCullRect)) {}
Canvas::Canvas(Rect bounds) : impl_(std::make_unique<Impl>(ToRect(bounds))) {}
Canvas::~Canvas() = default;
void Canvas::save() { impl_->builder.Save(); }

void Canvas::saveLayer(std::optional<Rect> bounds, const Paint& paint,
                       const ImageFilter* backdrop) {
  auto native_paint = Impl::PaintFor(paint);
  std::optional<DlRect> native_bounds;
  if (bounds) {
    native_bounds = ToRect(*bounds);
  }
  impl_->builder.SaveLayer(native_bounds, &native_paint, Impl::Filter(backdrop));
}

void Canvas::restore() { impl_->builder.Restore(); }
void Canvas::translate(float x, float y) { impl_->builder.Translate(x, y); }
void Canvas::scale(float x, float y) { impl_->builder.Scale(x, y); }
void Canvas::rotate(float degrees) { impl_->builder.Rotate(degrees); }
void Canvas::transform(float xx, float xy, float tx, float yx, float yy, float ty) {
  impl_->builder.Transform2DAffine(xx, xy, tx, yx, yy, ty);
}
void Canvas::clipRect(Rect bounds, ClipOp op, bool aa) {
  impl_->builder.ClipRect(ToRect(bounds), ToClip(op), aa);
}
void Canvas::clipPath(const Path& path, ClipOp op, bool aa) {
  impl_->builder.ClipPath(Impl::PathFor(path), ToClip(op), aa);
}
void Canvas::clear(Color color) { impl_->builder.DrawColor(ToColor(color), DlBlendMode::kSrc); }
void Canvas::drawRect(Rect bounds, const Paint& paint) {
  impl_->builder.DrawRect(ToRect(bounds), Impl::PaintFor(paint));
}
void Canvas::drawRoundRect(Rect bounds, float rx, float ry, const Paint& paint) {
  impl_->builder.DrawRoundRect(DlRoundRect::MakeRectXY(ToRect(bounds), rx, ry),
                               Impl::PaintFor(paint));
}
void Canvas::drawOval(Rect bounds, const Paint& paint) {
  impl_->builder.DrawOval(ToRect(bounds), Impl::PaintFor(paint));
}
void Canvas::drawArc(Rect bounds, float start_degrees, float sweep_degrees, bool use_center,
                     const Paint& paint) {
  impl_->builder.DrawArc(ToRect(bounds), start_degrees, sweep_degrees, use_center,
                         Impl::PaintFor(paint));
}
void Canvas::drawLine(Point start, Point end, const Paint& paint) {
  impl_->builder.DrawLine(ToPoint(start), ToPoint(end), Impl::PaintFor(paint));
}
void Canvas::drawPath(const Path& path, const Paint& paint) {
  impl_->builder.DrawPath(Impl::PathFor(path), Impl::PaintFor(paint));
}

void Canvas::drawShadow(const Path& path, Color color, float elevation, float device_pixel_ratio,
                        bool transparent_occluder) {
  if (elevation >= 0 && device_pixel_ratio > 0 && std::isfinite(elevation) &&
      std::isfinite(device_pixel_ratio)) {
    impl_->builder.DrawShadow(Impl::PathFor(path), ToColor(color), elevation, transparent_occluder,
                              device_pixel_ratio);
  }
}

void Canvas::drawVertices(VertexMode mode, std::span<const Point> positions,
                          std::span<const Color> colors, std::span<const uint16_t> indices,
                          BlendMode vertex_blend, const Paint& paint) {
  if (positions.size() < 3 || positions.size() > std::numeric_limits<int>::max() ||
      indices.size() > std::numeric_limits<int>::max() ||
      (!colors.empty() && colors.size() != positions.size()) ||
      (!indices.empty() && indices.size() < 3) ||
      std::any_of(indices.begin(), indices.end(),
                  [&](uint16_t index) { return index >= positions.size(); })) {
    throw std::invalid_argument("Invalid vertex positions, colors or indices");
  }
  std::vector<DlPoint> points;
  points.reserve(positions.size());
  for (Point point : positions) {
    points.push_back(ToPoint(point));
  }
  std::vector<DlColor> vertex_colors;
  vertex_colors.reserve(colors.size());
  for (Color color : colors) {
    vertex_colors.push_back(ToColor(color));
  }
  auto vertices = DlVertices::Make(
      static_cast<DlVertexMode>(mode), static_cast<int>(points.size()), points.data(), nullptr,
      vertex_colors.empty() ? nullptr : vertex_colors.data(), static_cast<int>(indices.size()),
      indices.empty() ? nullptr : indices.data());
  impl_->builder.DrawVertices(vertices, static_cast<DlBlendMode>(vertex_blend),
                              Impl::PaintFor(paint));
}

void Canvas::drawImage(const Image& image, Rect source, Rect destination, Sampling sampling,
                       const Paint* paint) {
  if (!image) {
    return;
  }
  impl_->rememberOwner(image.impl_->owner);
  const auto native_paint = paint ? std::optional(Impl::PaintFor(*paint)) : std::nullopt;
  impl_->builder.DrawImageRect(
      image.impl_->image, ToRect(source), ToRect(destination),
      sampling == Sampling::Nearest ? DlImageSampling::kNearestNeighbor : DlImageSampling::kLinear,
      native_paint ? &*native_paint : nullptr, DlSrcRectConstraint::kStrict);
}

void Canvas::drawParagraph(const Paragraph& paragraph, Point origin) {
  if (paragraph) {
    paragraph.impl_->paragraph->Paint(&impl_->builder, origin.x, origin.y);
  }
}

bool Canvas::drawGlyphs(const Font& font, std::span<const uint16_t> glyphs,
                        std::span<const Point> positions, Point origin, const Paint& paint) {
  if (!font || glyphs.size() != positions.size() ||
      glyphs.size() > std::numeric_limits<int>::max() || !std::isfinite(origin.x) ||
      !std::isfinite(origin.y)) {
    return false;
  }
  if (glyphs.empty()) {
    return true;
  }
  for (size_t i = 0; i < glyphs.size(); ++i) {
    if (glyphs[i] >= font.impl_->glyph_count || !std::isfinite(positions[i].x) ||
        !std::isfinite(positions[i].y)) {
      return false;
    }
  }
  SkTextBlobBuilder builder;
  const auto& run = builder.allocRunPos(font.impl_->font, static_cast<int>(glyphs.size()));
  std::copy(glyphs.begin(), glyphs.end(), run.glyphs);
  for (size_t i = 0; i < positions.size(); ++i) {
    run.points()[i] = {positions[i].x, positions[i].y};
  }
  auto blob = builder.make();
  if (!blob) {
    return false;
  }
  impl_->builder.DrawText(DlTextImpeller::MakeFromBlob(blob), origin.x, origin.y,
                          Impl::PaintFor(paint));
  return true;
}

void Canvas::drawDisplayList(const DisplayList& display_list, float opacity) {
  if (!display_list) {
    return;
  }
  for (const auto& owner : display_list.impl_->image_owners) {
    impl_->rememberOwner(owner);
  }
  impl_->builder.DrawDisplayList(display_list.impl_->list, opacity);
}

DisplayList Canvas::finish() {
  return DisplayList(std::make_shared<DisplayList::Impl>(impl_->builder.Build(),
                                                         std::exchange(impl_->image_owners, {})));
}

struct MetalRenderer::Impl {
  explicit Impl(std::shared_ptr<impeller::ContextMTL> context)
      : context(std::move(context)),
        aiks(this->context, impeller::TypographerContextSkia::Make()),
        transients(std::make_shared<impeller::SwapchainTransientsMTL>(
            this->context->GetResourceAllocator())),
        fonts(std::make_shared<txt::FontCollection>()),
        custom_fonts(sk_make_sp<txt::DynamicFontManager>()) {
    fonts->SetupDefaultFontManager(0);
    fonts->SetDynamicFontManager(custom_fonts);
  }

  std::shared_ptr<impeller::ContextMTL> context;
  impeller::AiksContext aiks;
  std::shared_ptr<impeller::SwapchainTransientsMTL> transients;
  std::shared_ptr<txt::FontCollection> fonts;
  sk_sp<txt::DynamicFontManager> custom_fonts;
  std::shared_ptr<const void> image_owner = std::make_shared<int>(0);

  bool ValidList(const DisplayList& list) const {
    return list && std::all_of(list.impl_->image_owners.begin(), list.impl_->image_owners.end(),
                               [&](const auto& owner) { return owner == image_owner; });
  }

  bool IsSampleableTexture(id<MTLTexture> texture) const {
    return texture && texture.device == context->GetMTLDevice() &&
           texture.textureType == MTLTextureType2D && texture.sampleCount == 1 &&
           texture.storageMode != MTLStorageModeMemoryless &&
           (texture.usage & MTLTextureUsageShaderRead) != 0 &&
           (texture.pixelFormat == MTLPixelFormatBGRA8Unorm ||
            texture.pixelFormat == MTLPixelFormatRGBA8Unorm);
  }

  bool SupportsSize(Size size) const {
    const auto maximum = context->GetResourceAllocator()->GetMaxTextureSizeSupported();
    return size.width > 0 && size.height > 0 && size.width <= maximum.width &&
           size.height <= maximum.height;
  }

  RenderResult Draw(const DisplayList& list, id<MTLTexture> texture, id<CAMetalDrawable> drawable) {
    if (!ValidList(list)) {
      return RenderResult::InvalidDisplayList;
    }
    if (!IsSampleableTexture(texture) || (texture.usage & MTLTextureUsageRenderTarget) == 0) {
      return RenderResult::InvalidTarget;
    }
    auto surface =
        impeller::SurfaceMTL::MakeFromTexture(context, texture, transients, std::nullopt, drawable);
    if (!surface || !surface->IsValid()) {
      return RenderResult::InvalidTarget;
    }
    const bool drew = impeller::RenderToTarget(
        aiks.GetContentContext(), surface->GetRenderTarget(), list.impl_->list,
        impeller::Rect::MakeSize(surface->GetSize()), true, drawable != nil);
    context->ResetThreadLocalState();
    if (!drew) {
      return RenderResult::SubmissionFailed;
    }
    if (drawable && !surface->Present()) {
      return RenderResult::SubmissionFailed;
    }
    return RenderResult::Success;
  }
};

std::unique_ptr<MetalRenderer> MetalRenderer::create(void* device, void* command_queue) {
  @autoreleasepool {
    id<MTLCommandQueue> queue = (__bridge id<MTLCommandQueue>)command_queue;
    id<MTLDevice> native_device = (__bridge id<MTLDevice>)device;
    if (!native_device) {
      native_device = queue ? queue.device : MTLCreateSystemDefaultDevice();
    }
    if (!native_device || (queue && queue.device != native_device)) {
      return nullptr;
    }
    if (!queue) {
      queue = [native_device newCommandQueue];
    }
    if (!queue) {
      return nullptr;
    }
    auto context =
        impeller::ContextMTL::Create(impeller::Flags{}, native_device, queue, ShaderLibraries(),
                                     std::make_shared<fml::SyncSwitch>(), "Impeller2D");
    if (!context || !context->IsValid()) {
      return nullptr;
    }
    auto impl = std::make_unique<Impl>(std::move(context));
    if (!impl->aiks.IsValid()) {
      return nullptr;
    }
    return std::unique_ptr<MetalRenderer>(new MetalRenderer(std::move(impl)));
  }
}

MetalRenderer::MetalRenderer(std::unique_ptr<Impl> impl) : impl_(std::move(impl)) {}
MetalRenderer::~MetalRenderer() {
  @autoreleasepool {
    impl_->context->Shutdown();
    impl_.reset();
  }
}

void* MetalRenderer::device() const noexcept {
  return (__bridge void*)impl_->context->GetMTLDevice();
}

RenderResult MetalRenderer::present(void* drawable, const DisplayList& list) {
  @autoreleasepool {
    id<CAMetalDrawable> native = (__bridge id<CAMetalDrawable>)drawable;
    return impl_->Draw(list, native.texture, native);
  }
}

RenderResult MetalRenderer::render(void* texture, const DisplayList& list) {
  @autoreleasepool {
    return impl_->Draw(list, (__bridge id<MTLTexture>)texture, nil);
  }
}

bool MetalRenderer::waitUntilIdle() {
  @autoreleasepool {
    if (!impl_->context->FlushCommandBuffers()) {
      return false;
    }
    id<MTLCommandBuffer> fence = impl_->context->CreateMTLCommandBuffer("Impeller2D fence");
    if (!fence) {
      return false;
    }
    [fence commit];
    [fence waitUntilCompleted];
    return fence.status == MTLCommandBufferStatusCompleted;
  }
}

Image MetalRenderer::createImage(Size size, std::span<const uint8_t> rgba) {
  @autoreleasepool {
    const auto byte_count = ByteCount(size);
    if (!impl_->SupportsSize(size) || !byte_count || rgba.size() != *byte_count) {
      return {};
    }
    impeller::TextureDescriptor descriptor;
    descriptor.format = impeller::PixelFormat::kR8G8B8A8UNormInt;
    descriptor.size = {size.width, size.height};
    descriptor.storage_mode = impeller::StorageMode::kHostVisible;
    auto texture = impl_->context->GetResourceAllocator()->CreateTexture(descriptor);
    if (!texture || !texture->SetContents(rgba.data(), rgba.size())) {
      return {};
    }
    return Image(std::make_shared<Image::Impl>(impeller::DlImageImpeller::Make(std::move(texture)),
                                               impl_->image_owner));
  }
}

Image MetalRenderer::decodeImage(std::span<const uint8_t> encoded) {
  if (encoded.empty() ||
      encoded.size() > static_cast<size_t>(std::numeric_limits<CFIndex>::max())) {
    return {};
  }
  fml::CFRef<CFDataRef> data(CFDataCreateWithBytesNoCopy(
      nullptr, encoded.data(), static_cast<CFIndex>(encoded.size()), kCFAllocatorNull));
  if (!data) {
    return {};
  }
  fml::CFRef<CGImageSourceRef> source(CGImageSourceCreateWithData(data, nullptr));
  if (!source) {
    return {};
  }
  fml::CFRef<CGImageRef> image(CGImageSourceCreateImageAtIndex(source, 0, nullptr));
  if (!image) {
    return {};
  }
  const auto width = CGImageGetWidth(image);
  const auto height = CGImageGetHeight(image);
  if (width > std::numeric_limits<int>::max() || height > std::numeric_limits<int>::max()) {
    return {};
  }
  const Size size{static_cast<int>(width), static_cast<int>(height)};
  const auto byte_count = ByteCount(size);
  if (!impl_->SupportsSize(size) || !byte_count) {
    return {};
  }
  std::vector<uint8_t> pixels(*byte_count);
  fml::CFRef<CGColorSpaceRef> color_space(CGColorSpaceCreateWithName(kCGColorSpaceSRGB));
  fml::CFRef<CGContextRef> bitmap(CGBitmapContextCreate(
      pixels.data(), width, height, 8, width * 4, color_space,
      static_cast<CGBitmapInfo>(kCGImageAlphaPremultipliedLast) | kCGBitmapByteOrder32Big));
  if (!bitmap) {
    return {};
  }
  CGContextSetBlendMode(bitmap, kCGBlendModeCopy);
  CGContextDrawImage(bitmap, CGRectMake(0, 0, width, height), image);
  return createImage(size, pixels);
}

Image MetalRenderer::wrapTexture(void* texture) {
  @autoreleasepool {
    id<MTLTexture> native = (__bridge id<MTLTexture>)texture;
    if (!impl_->IsSampleableTexture(native)) {
      return {};
    }
    impeller::TextureDescriptor descriptor;
    descriptor.format = impeller::FromMTLPixelFormat(native.pixelFormat);
    descriptor.size = {static_cast<int64_t>(native.width), static_cast<int64_t>(native.height)};
    descriptor.storage_mode = native.storageMode == MTLStorageModePrivate
                                  ? impeller::StorageMode::kDevicePrivate
                                  : impeller::StorageMode::kHostVisible;
    auto wrapped = impeller::TextureMTL::Wrapper(descriptor, native);
    if (!wrapped || !wrapped->IsValid()) {
      return {};
    }
    return Image(std::make_shared<Image::Impl>(impeller::DlImageImpeller::Make(std::move(wrapped)),
                                               impl_->image_owner));
  }
}

std::optional<Bitmap> MetalRenderer::rasterize(Size size, const DisplayList& list) {
  @autoreleasepool {
    const auto byte_count = ByteCount(size);
    if (!impl_->SupportsSize(size) || !byte_count || !impl_->ValidList(list)) {
      return std::nullopt;
    }
    auto descriptor = [MTLTextureDescriptor
        texture2DDescriptorWithPixelFormat:MTLPixelFormatRGBA8Unorm
                                     width:static_cast<NSUInteger>(size.width)
                                    height:static_cast<NSUInteger>(size.height)
                                 mipmapped:NO];
    descriptor.usage = MTLTextureUsageRenderTarget | MTLTextureUsageShaderRead;
    descriptor.storageMode = impl_->context->GetMTLDevice().hasUnifiedMemory
                                 ? MTLStorageModeShared
                                 : MTLStorageModeManaged;
    id<MTLTexture> texture = [impl_->context->GetMTLDevice() newTextureWithDescriptor:descriptor];
    if (impl_->Draw(list, texture, nil) != RenderResult::Success) {
      return std::nullopt;
    }
    id<MTLCommandBuffer> readback = impl_->context->CreateMTLCommandBuffer("Impeller2D readback");
    if (!readback) {
      return std::nullopt;
    }
    if (texture.storageMode == MTLStorageModeManaged) {
      id<MTLBlitCommandEncoder> blit = [readback blitCommandEncoder];
      if (!blit) {
        return std::nullopt;
      }
      [blit synchronizeResource:texture];
      [blit endEncoding];
    }
    [readback commit];
    [readback waitUntilCompleted];
    if (readback.status != MTLCommandBufferStatusCompleted) {
      return std::nullopt;
    }
    Bitmap bitmap{size, std::vector<uint8_t>(*byte_count)};
    [texture getBytes:bitmap.pixels.data()
          bytesPerRow:static_cast<size_t>(size.width) * 4
           fromRegion:MTLRegionMake2D(0, 0, size.width, size.height)
          mipmapLevel:0];
    return bitmap;
  }
}

bool MetalRenderer::registerFont(std::span<const uint8_t> data, std::string_view family) {
  @autoreleasepool {
    if (data.empty()) {
      return false;
    }
    auto font =
        txt::GetDefaultFontManager(0)->makeFromData(SkData::MakeWithCopy(data.data(), data.size()));
    if (!font) {
      return false;
    }
    auto& provider = impl_->custom_fonts->font_provider();
    if (family.empty()) {
      provider.RegisterTypeface(std::move(font));
    } else {
      provider.RegisterTypeface(std::move(font), std::string(family));
    }
    impl_->fonts->ClearFontFamilyCache();
    return true;
  }
}

Paragraph MetalRenderer::layoutText(std::span<const TextRun> runs, float width,
                                    const ParagraphStyle& style) {
  @autoreleasepool {
    if (runs.empty() || !std::isfinite(width) || width <= 0) {
      return {};
    }
    txt::ParagraphStyle paragraph_style;
    switch (style.align) {
      case TextAlign::Start:
        paragraph_style.text_align = txt::TextAlign::start;
        break;
      case TextAlign::Center:
        paragraph_style.text_align = txt::TextAlign::center;
        break;
      case TextAlign::End:
        paragraph_style.text_align = txt::TextAlign::end;
        break;
      case TextAlign::Justify:
        paragraph_style.text_align = txt::TextAlign::justify;
        break;
    }
    paragraph_style.text_direction = style.direction == TextDirection::RightToLeft
                                         ? txt::TextDirection::rtl
                                         : txt::TextDirection::ltr;
    if (style.max_lines > 0) {
      paragraph_style.max_lines = style.max_lines;
    }
    paragraph_style.ellipsis = style.ellipsis;
    auto builder = txt::ParagraphBuilder::CreateSkiaBuilder(paragraph_style, impl_->fonts, true);
    for (const auto& run : runs) {
      if (!std::isfinite(run.style.size) || run.style.size <= 0) {
        return {};
      }
      if (run.text.empty()) {
        continue;
      }
      txt::TextStyle run_style;
      run_style.color = ToColor(run.style.color).argb();
      run_style.font_size = run.style.size;
      run_style.font_weight = std::clamp(run.style.weight, 100, 900);
      run_style.font_style = run.style.italic ? txt::FontStyle::italic : txt::FontStyle::normal;
      if (!run.style.family.empty()) {
        run_style.font_families = {run.style.family};
      }
      run_style.locale = run.style.locale;
      run_style.letter_spacing = run.style.letter_spacing;
      builder->PushStyle(run_style);
      builder->AddText(reinterpret_cast<const uint8_t*>(run.text.data()), run.text.size());
      builder->Pop();
    }
    auto paragraph = builder->Build();
    if (!paragraph) {
      return {};
    }
    paragraph->Layout(width);
    return Paragraph(std::make_shared<Paragraph::Impl>(std::move(paragraph)));
  }
}

}  // namespace impeller2d
