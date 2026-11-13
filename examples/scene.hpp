#pragma once

#include <algorithm>

#include "impeller2d/engine.hpp"

inline impeller2d::DisplayList RecordScene(impeller2d::MetalRenderer& renderer,
                                           float width, float height) {
  using namespace impeller2d;
  Canvas canvas({0, 0, width, height});
  canvas.clear({0.055f, 0.075f, 0.13f, 1});

  const float scale = std::min(width / 720, height / 480);
  canvas.translate((width - 720 * scale) / 2, (height - 480 * scale) / 2);
  canvas.scale(scale, scale);

  const impeller2d::Rect card{36, 36, 648, 408};
  Path mask;
  mask.moveTo({36, 36})
      .lineTo({684, 36})
      .lineTo({684, 444})
      .lineTo({36, 444})
      .close();
  canvas.save();
  canvas.clipPath(mask);
  const std::array stops = {
      GradientStop{0, {0.10f, 0.16f, 0.30f, 1}},
      GradientStop{1, {0.17f, 0.07f, 0.31f, 1}},
  };
  Paint card_paint;
  card_paint.source = ColorSource::linear({36, 36}, {684, 444}, stops);
  canvas.drawRoundRect(card, 30, 30, card_paint);

  const std::array light = {
      GradientStop{0, {0.27f, 0.85f, 0.94f, 1}},
      GradientStop{1, {0.26f, 0.30f, 0.94f, 0.1f}},
  };
  Paint glow;
  glow.source = ColorSource::radial({511, 213}, 146, light, TileMode::Decal);
  glow.filter = ImageFilter::blur(16, 16);
  canvas.drawOval({352, 54, 318, 318}, glow);

  Path ribbon;
  ribbon.moveTo({369, 297})
      .cubicTo({453, 96}, {555, 365}, {633, 162})
      .cubicTo({569, 414}, {436, 160}, {369, 297})
      .close();
  const std::array ribbon_stops = {
      GradientStop{0, {0.22f, 0.82f, 0.86f, 1}},
      GradientStop{1, {0.69f, 0.46f, 0.97f, 1}},
  };
  Paint ribbon_paint;
  ribbon_paint.source =
      ColorSource::linear({378, 220}, {626, 260}, ribbon_stops);
  canvas.drawPath(ribbon, ribbon_paint);

  const std::array title = {
      TextRun{"Impeller",
              {.size = 52, .color = {0.94f, 0.97f, 1, 1}, .weight = 700}},
      TextRun{" 2D",
              {.size = 52, .color = {0.35f, 0.85f, 0.92f, 1}, .weight = 700}},
  };
  canvas.drawParagraph(renderer.layoutText(title, 510), {76, 122});
  const std::array caption = {
      TextRun{"C++ · Metal", {.size = 22, .color = {0.73f, 0.80f, 0.94f, 1}}},
      TextRun{"\n原生二维渲染",
              {.size = 22, .color = {0.73f, 0.80f, 0.94f, 1}}},
  };
  canvas.drawParagraph(renderer.layoutText(caption, 290), {80, 206});
  canvas.restore();
  return canvas.finish();
}
