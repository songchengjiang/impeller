// Copyright 2013 The Flutter Authors. All rights reserved.
// Use of this source code is governed by a BSD-style license that can be
// found in the LICENSE file.

#ifndef FLUTTER_IMPELLER_DISPLAY_LIST_DL_DISPATCHER_H_
#define FLUTTER_IMPELLER_DISPLAY_LIST_DL_DISPATCHER_H_

#include <map>
#include <memory>

#include "display_list/dl_op_receiver.h"
#include "display_list/geometry/dl_geometry_types.h"
#include "display_list/geometry/dl_path.h"
#include "display_list/utils/dl_receiver_utils.h"
#include "fml/logging.h"
#include "impeller/display_list/aiks_context.h"
#include "impeller/display_list/canvas.h"
#include "impeller/display_list/paint.h"
#include "impeller/entity/contents/content_context.h"
#include "impeller/geometry/rect.h"

#include "display_list/image/dl_image.h"

namespace impeller {

#include "impeller/core/texture.h"

using DlScalar = impeller_dl::DlScalar;
using DlPoint = impeller_dl::DlPoint;
using DlRect = impeller_dl::DlRect;
using DlIRect = impeller_dl::DlIRect;
using DlRoundRect = impeller_dl::DlRoundRect;
using DlRoundSuperellipse = impeller_dl::DlRoundSuperellipse;
using DlPath = impeller_dl::DlPath;

//////////////////////////////////////////////////////////////////////////
/// Important implementation note.
///
/// The Impeller DisplayList Dispatcher implementation is divided into
/// two parts and conducted in two passes.
///
/// The first pass is conducted using the FirstPassDispatcher which
/// examines the rendering ops for important conditions needed by the
/// rendering pass and computes some needed information for them.
///
/// The second pass is conducted using CanvasDlDispatcher to perform the
/// actual rendering using a Canvas and data provided by the first pass.
///
/// @important It is important to note that the 2 passes perform slightly
/// different DisplayList culling and may process different subsets of the
/// frame's operations.
/// See https://github.com/flutter/flutter/issues/182639
///
/// Given the above issue any data precomputed by the first pass should
/// be presented in a way that doesn't assume a 1:1 correlation of the
/// rendering operations in both passes (perhaps provide it in a map
/// instead of a vector). While we have not yet observed and cases where
/// an operation is missed during the first pass but still processed in
/// the rendering pass, it would be wise to include a backup plan in
/// the canvas dispatcher for when the data was not forwarded.
//////////////////////////////////////////////////////////////////////////

/// Base (virtual) dispatcher utility class to implement most DlOpReceiver
/// operations for other specific classes.
class DlDispatcherBase : public impeller_dl::DlOpReceiver {
 public:
  explicit DlDispatcherBase() {}

  virtual ~DlDispatcherBase() = default;

  // |impeller_dl::DlOpReceiver|
  void setAntiAlias(bool aa) override;

  // |impeller_dl::DlOpReceiver|
  void setDrawStyle(impeller_dl::DlDrawStyle style) override;

  // |impeller_dl::DlOpReceiver|
  void setColor(impeller_dl::DlColor color) override;

  // |impeller_dl::DlOpReceiver|
  void setStrokeWidth(DlScalar width) override;

  // |impeller_dl::DlOpReceiver|
  void setStrokeMiter(DlScalar limit) override;

  // |impeller_dl::DlOpReceiver|
  void setStrokeCap(impeller_dl::DlStrokeCap cap) override;

  // |impeller_dl::DlOpReceiver|
  void setStrokeJoin(impeller_dl::DlStrokeJoin join) override;

  // |impeller_dl::DlOpReceiver|
  void setColorSource(const impeller_dl::DlColorSource* source) override;

  // |impeller_dl::DlOpReceiver|
  void setColorFilter(const impeller_dl::DlColorFilter* filter) override;

  // |impeller_dl::DlOpReceiver|
  void setInvertColors(bool invert) override;

  // |impeller_dl::DlOpReceiver|
  void setBlendMode(impeller_dl::DlBlendMode mode) override;

  // |impeller_dl::DlOpReceiver|
  void setMaskFilter(const impeller_dl::DlMaskFilter* filter) override;

  // |impeller_dl::DlOpReceiver|
  void setImageFilter(const impeller_dl::DlImageFilter* filter) override;

  // |impeller_dl::DlOpReceiver|
  void save(uint32_t total_content_depth) override;

  // |impeller_dl::DlOpReceiver|
  void saveLayer(const DlRect& bounds,
                 const impeller_dl::SaveLayerOptions& options,
                 uint32_t total_content_depth,
                 impeller_dl::DlBlendMode max_content_mode,
                 const impeller_dl::DlImageFilter* backdrop,
                 std::optional<int64_t> backdrop_id) override;

  // |impeller_dl::DlOpReceiver|
  void restore() override;

  // |impeller_dl::DlOpReceiver|
  void translate(DlScalar tx, DlScalar ty) override;

  // |impeller_dl::DlOpReceiver|
  void scale(DlScalar sx, DlScalar sy) override;

  // |impeller_dl::DlOpReceiver|
  void rotate(DlScalar degrees) override;

  // |impeller_dl::DlOpReceiver|
  void skew(DlScalar sx, DlScalar sy) override;

  // |impeller_dl::DlOpReceiver|
  void transform2DAffine(DlScalar mxx,
                         DlScalar mxy,
                         DlScalar mxt,
                         DlScalar myx,
                         DlScalar myy,
                         DlScalar myt) override;

  // |impeller_dl::DlOpReceiver|
  void transformFullPerspective(DlScalar mxx,
                                DlScalar mxy,
                                DlScalar mxz,
                                DlScalar mxt,
                                DlScalar myx,
                                DlScalar myy,
                                DlScalar myz,
                                DlScalar myt,
                                DlScalar mzx,
                                DlScalar mzy,
                                DlScalar mzz,
                                DlScalar mzt,
                                DlScalar mwx,
                                DlScalar mwy,
                                DlScalar mwz,
                                DlScalar mwt) override;

  // |impeller_dl::DlOpReceiver|
  void transformReset() override;

  // |impeller_dl::DlOpReceiver|
  void clipRect(const DlRect& rect,
                impeller_dl::DlClipOp clip_op,
                bool is_aa) override;

  // |impeller_dl::DlOpReceiver|
  void clipOval(const DlRect& bounds,
                impeller_dl::DlClipOp clip_op,
                bool is_aa) override;

  // |impeller_dl::DlOpReceiver|
  void clipRoundRect(const DlRoundRect& rrect,
                     impeller_dl::DlClipOp clip_op,
                     bool is_aa) override;

  // |impeller_dl::DlOpReceiver|
  void clipRoundSuperellipse(const DlRoundSuperellipse& rse,
                             impeller_dl::DlClipOp clip_op,
                             bool is_aa) override;

  // |impeller_dl::DlOpReceiver|
  void clipPath(const DlPath& path,
                impeller_dl::DlClipOp clip_op,
                bool is_aa) override;

  // |impeller_dl::DlOpReceiver|
  void drawColor(impeller_dl::DlColor color, impeller_dl::DlBlendMode mode) override;

  // |impeller_dl::DlOpReceiver|
  void drawPaint() override;

  // |impeller_dl::DlOpReceiver|
  void drawLine(const DlPoint& p0, const DlPoint& p1) override;

  // |impeller_dl::DlOpReceiver|
  void drawDashedLine(const DlPoint& p0,
                      const DlPoint& p1,
                      DlScalar on_length,
                      DlScalar off_length) override;

  // |impeller_dl::DlOpReceiver|
  void drawRect(const DlRect& rect) override;

  // |impeller_dl::DlOpReceiver|
  void drawOval(const DlRect& bounds) override;

  // |impeller_dl::DlOpReceiver|
  void drawCircle(const DlPoint& center, DlScalar radius) override;

  // |impeller_dl::DlOpReceiver|
  void drawRoundRect(const DlRoundRect& rrect) override;

  // |impeller_dl::DlOpReceiver|
  void drawDiffRoundRect(const DlRoundRect& outer,
                         const DlRoundRect& inner) override;

  // |impeller_dl::DlOpReceiver|
  void drawRoundSuperellipse(const DlRoundSuperellipse& rse) override;

  // |impeller_dl::DlOpReceiver|
  void drawPath(const DlPath& path) override;

  // |impeller_dl::DlOpReceiver|
  void drawArc(const DlRect& oval_bounds,
               DlScalar start_degrees,
               DlScalar sweep_degrees,
               bool use_center) override;

  // |impeller_dl::DlOpReceiver|
  void drawPoints(impeller_dl::DlPointMode mode,
                  uint32_t count,
                  const DlPoint points[]) override;

  // |impeller_dl::DlOpReceiver|
  void drawVertices(const std::shared_ptr<impeller_dl::DlVertices>& vertices,
                    impeller_dl::DlBlendMode dl_mode) override;

  // |impeller_dl::DlOpReceiver|
  void drawImage(const sk_sp<impeller_dl::DlImage> image,
                 const DlPoint& point,
                 impeller_dl::DlImageSampling sampling,
                 bool render_with_attributes) override;

  // |impeller_dl::DlOpReceiver|
  void drawImageRect(const sk_sp<impeller_dl::DlImage> image,
                     const DlRect& src,
                     const DlRect& dst,
                     impeller_dl::DlImageSampling sampling,
                     bool render_with_attributes,
                     impeller_dl::DlSrcRectConstraint constraint) override;

  // |impeller_dl::DlOpReceiver|
  void drawImageNine(const sk_sp<impeller_dl::DlImage> image,
                     const DlIRect& center,
                     const DlRect& dst,
                     impeller_dl::DlFilterMode filter,
                     bool render_with_attributes) override;

  // |impeller_dl::DlOpReceiver|
  void drawAtlas(const sk_sp<impeller_dl::DlImage> atlas,
                 const RSTransform xform[],
                 const DlRect tex[],
                 const impeller_dl::DlColor colors[],
                 int count,
                 impeller_dl::DlBlendMode mode,
                 impeller_dl::DlImageSampling sampling,
                 const DlRect* cull_rect,
                 bool render_with_attributes) override;

  // |impeller_dl::DlOpReceiver|
  void drawDisplayList(const sk_sp<impeller_dl::DisplayList> display_list,
                       DlScalar opacity) override;

  // |impeller_dl::DlOpReceiver|
  void drawText(const std::shared_ptr<impeller_dl::DlText>& text,
                DlScalar x,
                DlScalar y) override;

  // |impeller_dl::DlOpReceiver|
  void drawShadow(const DlPath& path,
                  const impeller_dl::DlColor color,
                  const DlScalar elevation,
                  bool transparent_occluder,
                  DlScalar dpr) override;

  virtual Canvas& GetCanvas() = 0;

  virtual ContentContext& GetContentContext() const = 0;

  std::shared_ptr<Texture> GetTexture(const sk_sp<impeller_dl::DlImage>& image);

 protected:
  Paint paint_;
  Matrix initial_matrix_;

  static void SimplifyOrDrawPath(Canvas& canvas,
                                 const DlPath& cache,
                                 const Paint& paint);
};

/// Specific non-virtual dispatcher utility class that uses DlDispatcherBase
/// to implement most operations but provides additional implementation of
/// operations that are specific to the rendering pass of the Impeller
/// 2-pass rendering procedure.
class CanvasDlDispatcher : public DlDispatcherBase {
 public:
  CanvasDlDispatcher(ContentContext& renderer,
                     RenderTarget& render_target,
                     bool is_onscreen,
                     bool has_root_backdrop_filter,
                     impeller_dl::DlBlendMode max_root_blend_mode,
                     IRect32 cull_rect);

  ~CanvasDlDispatcher() = default;

  void SetBackdropData(std::unordered_map<int64_t, BackdropData> backdrop,
                       size_t backdrop_count);

  // |impeller_dl::DlOpReceiver|
  void save() override {
    // This dispatcher should never be used with the save() variant
    // that does not include the content_depth parameter.
    FML_UNREACHABLE();
  }
  using DlDispatcherBase::save;

  // |impeller_dl::DlOpReceiver|
  void saveLayer(const DlRect& bounds,
                 const impeller_dl::SaveLayerOptions options,
                 const impeller_dl::DlImageFilter* backdrop,
                 std::optional<int64_t> backdrop_id) override {
    // This dispatcher should never be used with the saveLayer() variant
    // that does not include the content_depth parameter.
    FML_UNREACHABLE();
  }
  using DlDispatcherBase::saveLayer;

  bool FinishRecording() { return canvas_.EndReplay(); }

  // |impeller_dl::DlOpReceiver|
  void drawVertices(const std::shared_ptr<impeller_dl::DlVertices>& vertices,
                    impeller_dl::DlBlendMode dl_mode) override;

 private:
  Canvas canvas_;
  ContentContext& renderer_;

  Canvas& GetCanvas() override;
  ContentContext& GetContentContext() const override;
};

/// Performs a first pass over the display list to collect information
/// that will be useful in a second pass by the CanvasDlDispatcher.
/// This class collects things like text frames and backdrop filters.
class FirstPassDispatcher : public impeller_dl::IgnoreAttributeDispatchHelper,
                            public impeller_dl::IgnoreDrawDispatchHelper {
 public:
  FirstPassDispatcher(const ContentContext& renderer,
                      const Matrix& initial_matrix,
                      const Rect cull_rect);

  ~FirstPassDispatcher();

  void save() override;

  void saveLayer(const DlRect& bounds,
                 const impeller_dl::SaveLayerOptions options,
                 const impeller_dl::DlImageFilter* backdrop,
                 std::optional<int64_t> backdrop_id) override;

  void restore() override;

  // |impeller_dl::DlOpReceiver|
  void clipRect(const DlRect& rect,
                impeller_dl::DlClipOp clip_op,
                bool is_aa) override;

  // |impeller_dl::DlOpReceiver|
  void clipOval(const DlRect& bounds,
                impeller_dl::DlClipOp clip_op,
                bool is_aa) override;

  // |impeller_dl::DlOpReceiver|
  void clipRoundRect(const DlRoundRect& rrect,
                     impeller_dl::DlClipOp clip_op,
                     bool is_aa) override;

  // |impeller_dl::DlOpReceiver|
  void clipPath(const DlPath& path,
                impeller_dl::DlClipOp clip_op,
                bool is_aa) override;

  // |impeller_dl::DlOpReceiver|
  void clipRoundSuperellipse(const DlRoundSuperellipse& rse,
                             impeller_dl::DlClipOp clip_op,
                             bool is_aa) override;

  void translate(DlScalar tx, DlScalar ty) override;

  void scale(DlScalar sx, DlScalar sy) override;

  void rotate(DlScalar degrees) override;

  void skew(DlScalar sx, DlScalar sy) override;

  // clang-format off
  // 2x3 2D affine subset of a 4x4 transform in row major order
  void transform2DAffine(DlScalar mxx, DlScalar mxy, DlScalar mxt,
                         DlScalar myx, DlScalar myy, DlScalar myt) override;
  // clang-format on

  // clang-format off
  // full 4x4 transform in row major order
  void transformFullPerspective(
      DlScalar mxx, DlScalar mxy, DlScalar mxz, DlScalar mxt,
      DlScalar myx, DlScalar myy, DlScalar myz, DlScalar myt,
      DlScalar mzx, DlScalar mzy, DlScalar mzz, DlScalar mzt,
      DlScalar mwx, DlScalar mwy, DlScalar mwz, DlScalar mwt) override;
  // clang-format on

  void transformReset() override;

  void drawText(const std::shared_ptr<impeller_dl::DlText>& text,
                DlScalar x,
                DlScalar y) override;

  void drawDisplayList(const sk_sp<impeller_dl::DisplayList> display_list,
                       DlScalar opacity) override;

  // |impeller_dl::DlOpReceiver|
  void setDrawStyle(impeller_dl::DlDrawStyle style) override;

  // |impeller_dl::DlOpReceiver|
  void setColor(impeller_dl::DlColor color) override;

  // |impeller_dl::DlOpReceiver|
  void setStrokeWidth(DlScalar width) override;

  // |impeller_dl::DlOpReceiver|
  void setStrokeMiter(DlScalar limit) override;

  // |impeller_dl::DlOpReceiver|
  void setStrokeCap(impeller_dl::DlStrokeCap cap) override;

  // |impeller_dl::DlOpReceiver|
  void setStrokeJoin(impeller_dl::DlStrokeJoin join) override;

  // |impeller_dl::DlOpReceiver|
  void setImageFilter(const impeller_dl::DlImageFilter* filter) override;

  std::pair<std::unordered_map<int64_t, BackdropData>, size_t>
  TakeBackdropData();

 private:
  const Rect GetCurrentLocalCullingBounds() const;

  const ContentContext& renderer_;
  Matrix matrix_;
  std::vector<Matrix> stack_;
  std::unordered_map<int64_t, BackdropData> backdrop_data_;
  // note: cull rects are always in the global coordinate space.
  std::vector<Rect> cull_rect_state_;
  bool has_image_filter_ = false;
  size_t backdrop_count_ = 0;
  Paint paint_;
};

/// Render the provided display list to a texture with the given size.
std::shared_ptr<Texture> DisplayListToTexture(
    const sk_sp<impeller_dl::DisplayList>& display_list,
    ISize size,
    ContentContext& context,
    bool reset_host_buffer = true,
    bool generate_mips = false,
    std::optional<PixelFormat> target_pixel_format = std::nullopt);

/// Render the provided display list to a texture with the given size.
std::shared_ptr<Texture> DisplayListToTexture(
    const sk_sp<impeller_dl::DisplayList>& display_list,
    ISize size,
    AiksContext& context,
    bool reset_host_buffer = true,
    bool generate_mips = false,
    std::optional<PixelFormat> target_pixel_format = std::nullopt);

/// @brief Render the provided display list to the render target.
///
/// If [is_onscreen] is true, then the onscreen command buffer will be
/// submitted via Context::SubmitOnscreen.
bool RenderToTarget(ContentContext& context,
                    RenderTarget render_target,
                    const sk_sp<impeller_dl::DisplayList>& display_list,
                    Rect cull_rect,
                    bool reset_host_buffer,
                    bool is_onscreen = true);

}  // namespace impeller

#endif  // FLUTTER_IMPELLER_DISPLAY_LIST_DL_DISPATCHER_H_
