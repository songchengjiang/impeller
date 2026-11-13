// Copyright 2013 The Flutter Authors. All rights reserved.
// Use of this source code is governed by a BSD-style license that can be
// found in the LICENSE file.

#ifndef FLUTTER_IMPELLER_DISPLAY_LIST_SKIA_CONVERSIONS_H_
#define FLUTTER_IMPELLER_DISPLAY_LIST_SKIA_CONVERSIONS_H_

#include "display_list/dl_blend_mode.h"
#include "display_list/dl_color.h"
#include "display_list/dl_sampling_options.h"
#include "impeller/core/sampler_descriptor.h"
#include "impeller/geometry/color.h"

namespace impeller {
namespace skia_conversions {

Color ToColor(const impeller_dl::DlColor& color);

impeller::SamplerDescriptor ToSamplerDescriptor(
    const impeller_dl::DlImageSampling options);

}  // namespace skia_conversions
}  // namespace impeller

#endif  // FLUTTER_IMPELLER_DISPLAY_LIST_SKIA_CONVERSIONS_H_
