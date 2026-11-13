// Copyright 2013 The Flutter Authors. All rights reserved.
// Use of this source code is governed by a BSD-style license that can be
// found in the LICENSE file.

#include "display_list/effects/color_filters/dl_linear_to_srgb_gamma_color_filter.h"

namespace impeller_dl {

const std::shared_ptr<DlLinearToSrgbGammaColorFilter>
    DlLinearToSrgbGammaColorFilter::kInstance =
        std::make_shared<DlLinearToSrgbGammaColorFilter>();

}  // namespace impeller_dl
