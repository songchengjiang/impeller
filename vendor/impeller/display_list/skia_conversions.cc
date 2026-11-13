// Copyright 2013 The Flutter Authors. All rights reserved.
// Use of this source code is governed by a BSD-style license that can be
// found in the LICENSE file.

#include "impeller/display_list/skia_conversions.h"
#include "display_list/dl_blend_mode.h"
#include "display_list/dl_color.h"
#include "modules/skparagraph/include/Paragraph.h"

namespace impeller {
namespace skia_conversions {

Color ToColor(const impeller_dl::DlColor& color) {
  FML_DCHECK(color.getColorSpace() == impeller_dl::DlColorSpace::kExtendedSRGB ||
             color.getColorSpace() == impeller_dl::DlColorSpace::kSRGB);
  return {
      static_cast<Scalar>(color.getRedF()),    //
      static_cast<Scalar>(color.getGreenF()),  //
      static_cast<Scalar>(color.getBlueF()),   //
      static_cast<Scalar>(color.getAlphaF())   //
  };
}

impeller::SamplerDescriptor ToSamplerDescriptor(
    const impeller_dl::DlImageSampling options) {
  impeller::SamplerDescriptor desc;
  switch (options) {
    case impeller_dl::DlImageSampling::kNearestNeighbor:
      desc.min_filter = desc.mag_filter = impeller::MinMagFilter::kNearest;
      desc.mip_filter = impeller::MipFilter::kBase;
      desc.label = "Nearest Sampler";
      break;
    case impeller_dl::DlImageSampling::kLinear:
      desc.min_filter = desc.mag_filter = impeller::MinMagFilter::kLinear;
      desc.mip_filter = impeller::MipFilter::kBase;
      desc.label = "Linear Sampler";
      break;
    case impeller_dl::DlImageSampling::kCubic:
    case impeller_dl::DlImageSampling::kMipmapLinear:
      desc.min_filter = desc.mag_filter = impeller::MinMagFilter::kLinear;
      desc.mip_filter = impeller::MipFilter::kLinear;
      desc.label = "Mipmap Linear Sampler";
      break;
  }
  return desc;
}

}  // namespace skia_conversions
}  // namespace impeller
