#pragma once

#include <array>
#include <cstddef>
#include <cstdint>
#include <memory>
#include <optional>
#include <span>
#include <string>
#include <string_view>
#include <vector>

#define IMPELLER2D_API __attribute__((visibility("default")))

namespace impeller2d {

struct Point {
  float x = 0;
  float y = 0;
};

struct Size {
  int width = 0;
  int height = 0;
};

struct Rect {
  float x = 0;
  float y = 0;
  float width = 0;
  float height = 0;
};

struct Color {
  float red = 0;
  float green = 0;
  float blue = 0;
  float alpha = 1;
};

enum class FillRule { NonZero, EvenOdd };
enum class ClipOp { Intersect, Difference };
enum class DrawStyle { Fill, Stroke, StrokeAndFill };
enum class StrokeCap { Butt, Round, Square };
enum class StrokeJoin { Miter, Round, Bevel };
enum class TileMode { Clamp, Repeat, Mirror, Decal };
enum class Sampling { Nearest, Linear };
enum class BlendMode {
  Clear,
  Source,
  Destination,
  SourceOver,
  DestinationOver,
  SourceIn,
  DestinationIn,
  SourceOut,
  DestinationOut,
  SourceAtop,
  DestinationAtop,
  Xor,
  Plus,
  Modulate,
  Screen,
  Overlay,
  Darken,
  Lighten,
  ColorDodge,
  ColorBurn,
  HardLight,
  SoftLight,
  Difference,
  Exclusion,
  Multiply,
  Hue,
  Saturation,
  Color,
  Luminosity,
};

class IMPELLER2D_API Path {
 public:
  Path& moveTo(Point point);
  Path& lineTo(Point point);
  Path& quadraticTo(Point control, Point end);
  Path& cubicTo(Point first, Point second, Point end);
  Path& close();
  Path& addRect(Rect bounds);
  Path& addOval(Rect bounds);
  Path& setFillRule(FillRule rule);

 private:
  friend class Canvas;
  enum class Verb { Move, Line, Quadratic, Cubic, Close, Rect, Oval };
  struct Command {
    Verb verb;
    Point first{};
    Point second{};
    Point third{};
    Rect bounds{};
  };
  std::vector<Command> commands_;
  FillRule fill_rule_ = FillRule::NonZero;
};

struct GradientStop {
  float offset;
  Color color;
};

class IMPELLER2D_API ColorSource {
 public:
  static ColorSource linear(Point from, Point to,
                            std::span<const GradientStop> stops,
                            TileMode tile = TileMode::Clamp);
  static ColorSource radial(Point center, float radius,
                            std::span<const GradientStop> stops,
                            TileMode tile = TileMode::Clamp);
  static ColorSource sweep(Point center, float start_degrees, float end_degrees,
                           std::span<const GradientStop> stops,
                           TileMode tile = TileMode::Clamp);

 private:
  friend class Canvas;
  struct Impl;
  explicit ColorSource(std::shared_ptr<const Impl> impl);
  std::shared_ptr<const Impl> impl_;
};

class IMPELLER2D_API ImageFilter {
 public:
  static ImageFilter blur(float sigma_x, float sigma_y,
                          TileMode tile = TileMode::Decal);
  static ImageFilter colorMatrix(const std::array<float, 20>& matrix);
  static ImageFilter dilate(float radius_x, float radius_y);
  static ImageFilter erode(float radius_x, float radius_y);
  static ImageFilter compose(const ImageFilter& outer,
                             const ImageFilter& inner);

 private:
  friend class Canvas;
  struct Impl;
  explicit ImageFilter(std::shared_ptr<const Impl> impl);
  std::shared_ptr<const Impl> impl_;
};

struct Paint {
  Color color;
  BlendMode blend = BlendMode::SourceOver;
  DrawStyle style = DrawStyle::Fill;
  StrokeCap cap = StrokeCap::Butt;
  StrokeJoin join = StrokeJoin::Miter;
  float stroke_width = 0;
  float miter_limit = 4;
  bool antialias = true;
  std::optional<ColorSource> source;
  std::optional<ImageFilter> filter;
};

enum class VertexMode { Triangles, TriangleStrip, TriangleFan };

class IMPELLER2D_API DisplayList {
 public:
  DisplayList() = default;
  explicit operator bool() const noexcept;

 private:
  friend class Canvas;
  friend class MetalRenderer;
  struct Impl;
  explicit DisplayList(std::shared_ptr<const Impl> impl);
  std::shared_ptr<const Impl> impl_;
};

class IMPELLER2D_API Image {
 public:
  Image() = default;
  explicit operator bool() const noexcept;
  Size size() const noexcept;

 private:
  friend class Canvas;
  friend class MetalRenderer;
  struct Impl;
  explicit Image(std::shared_ptr<const Impl> impl);
  std::shared_ptr<const Impl> impl_;
};

enum class TextAlign { Start, Center, End, Justify };
enum class TextDirection { LeftToRight, RightToLeft };

struct TextStyle {
  std::string family;
  float size = 14;
  Color color;
  int weight = 400;
  bool italic = false;
  float letter_spacing = 0;
  std::string locale;
};

struct ParagraphStyle {
  TextAlign align = TextAlign::Start;
  TextDirection direction = TextDirection::LeftToRight;
  std::size_t max_lines = 0;
  std::u16string ellipsis;
};

struct TextRun {
  std::string_view text;
  TextStyle style;
};

class IMPELLER2D_API Font {
 public:
  Font() = default;
  // Takes a borrowed CTFontRef and retains its typeface.
  static Font fromCoreText(const void* font);
  explicit operator bool() const noexcept;

 private:
  friend class Canvas;
  struct Impl;
  explicit Font(std::shared_ptr<const Impl> impl);
  std::shared_ptr<const Impl> impl_;
};

class IMPELLER2D_API Paragraph {
 public:
  Paragraph() = default;
  explicit operator bool() const noexcept;
  float height() const;
  float longestLine() const;

 private:
  friend class Canvas;
  friend class MetalRenderer;
  struct Impl;
  explicit Paragraph(std::shared_ptr<Impl> impl);
  std::shared_ptr<Impl> impl_;
};

class IMPELLER2D_API Canvas {
 public:
  Canvas();
  explicit Canvas(Rect bounds);
  ~Canvas();
  Canvas(const Canvas&) = delete;
  Canvas& operator=(const Canvas&) = delete;

  void save();
  void saveLayer(std::optional<Rect> bounds = {}, const Paint& paint = {},
                 const ImageFilter* backdrop = nullptr);
  void restore();
  void translate(float x, float y);
  void scale(float x, float y);
  void rotate(float degrees);
  void transform(float xx, float xy, float tx, float yx, float yy, float ty);
  void clipRect(Rect bounds, ClipOp op = ClipOp::Intersect, bool aa = true);
  void clipPath(const Path& path, ClipOp op = ClipOp::Intersect,
                bool aa = true);
  void clear(Color color);
  void drawRect(Rect bounds, const Paint& paint);
  void drawRoundRect(Rect bounds, float rx, float ry, const Paint& paint);
  void drawOval(Rect bounds, const Paint& paint);
  void drawArc(Rect bounds, float start_degrees, float sweep_degrees,
               bool use_center, const Paint& paint);
  void drawLine(Point start, Point end, const Paint& paint);
  void drawPath(const Path& path, const Paint& paint);
  void drawShadow(const Path& path, Color color, float elevation,
                  float device_pixel_ratio, bool transparent_occluder = false);
  void drawVertices(VertexMode mode, std::span<const Point> positions,
                    std::span<const Color> colors,
                    std::span<const std::uint16_t> indices,
                    BlendMode vertex_blend, const Paint& paint);
  void drawImage(const Image& image, Rect source, Rect destination,
                 Sampling sampling = Sampling::Linear,
                 const Paint* paint = nullptr);
  void drawParagraph(const Paragraph& paragraph, Point origin);
  // Records pre-shaped glyph IDs and positions without shaping again.
  bool drawGlyphs(const Font& font, std::span<const std::uint16_t> glyphs,
                  std::span<const Point> positions, Point origin,
                  const Paint& paint);
  void drawDisplayList(const DisplayList& display_list, float opacity = 1);
  // Returns a replayable recording and resets the Canvas to its initial state.
  DisplayList finish();

 private:
  struct Impl;
  std::unique_ptr<Impl> impl_;
};

enum class RenderResult {
  Success,
  InvalidDisplayList,
  InvalidTarget,
  SubmissionFailed,
};

struct Bitmap {
  Size size;
  // Top-down, tightly packed premultiplied RGBA8.
  std::vector<std::uint8_t> pixels;
};

// Pass Objective-C Metal objects as borrowed void pointers using __bridge.
// MetalRenderer retains its device and queue. A renderer and its Canvas or
// typography operations must be used serially. Callers own their event loop.
class IMPELLER2D_API MetalRenderer {
 public:
  static std::unique_ptr<MetalRenderer> create(void* device = nullptr,
                                               void* command_queue = nullptr);
  ~MetalRenderer();
  MetalRenderer(const MetalRenderer&) = delete;
  MetalRenderer& operator=(const MetalRenderer&) = delete;

  void* device() const noexcept;
  // Submits the list and presents a caller-acquired CAMetalDrawable.
  RenderResult present(void* drawable, const DisplayList& display_list);
  // Renders to a caller-owned MTLTexture and submits on the renderer's queue.
  // Use the same queue or waitUntilIdle before reading it from another queue.
  RenderResult render(void* texture, const DisplayList& display_list);
  bool waitUntilIdle();

  // Uploads tightly packed, premultiplied RGBA8. The input is copied.
  Image createImage(Size size, std::span<const std::uint8_t> rgba);
  // Decodes the first frame of an ImageIO-supported format into sRGB RGBA8.
  Image decodeImage(std::span<const std::uint8_t> encoded);
  // Samples a caller-owned RGBA8Unorm or BGRA8Unorm texture without a copy.
  // The Image retains the texture. Its contents must use premultiplied alpha.
  Image wrapTexture(void* texture);
  // GPU rendering followed by synchronous CPU readback.
  std::optional<Bitmap> rasterize(Size size, const DisplayList& display_list);

  bool registerFont(std::span<const std::uint8_t> data,
                    std::string_view family = {});
  Paragraph layoutText(std::span<const TextRun> runs, float width,
                       const ParagraphStyle& style = {});

 private:
  struct Impl;
  explicit MetalRenderer(std::unique_ptr<Impl> impl);
  std::unique_ptr<Impl> impl_;
};

}  // namespace impeller2d

#undef IMPELLER2D_API
