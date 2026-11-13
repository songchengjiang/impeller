// Copyright 2013 The Flutter Authors. All rights reserved.
// Use of this source code is governed by a BSD-style license that can be
// found in the LICENSE file.

#include "impeller/display_list/dl_text_impeller.h"

#include "impeller/typographer/backends/skia/text_frame_skia.h"

namespace impeller_dl {

std::shared_ptr<DlTextImpeller> DlTextImpeller::Make(
    const std::shared_ptr<impeller::TextFrame>& frame) {
  return std::make_shared<DlTextImpeller>(frame);
}

std::shared_ptr<DlTextImpeller> DlTextImpeller::MakeFromBlob(
    const sk_sp<SkTextBlob>& blob) {
  return DlTextImpeller::Make(impeller::MakeTextFrameFromTextBlobSkia(blob));
}

DlTextImpeller::DlTextImpeller(
    const std::shared_ptr<impeller::TextFrame>& frame)
    : frame_(frame) {}

}  // namespace impeller_dl
