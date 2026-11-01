#pragma once

#include <algorithm>
#include <cstddef>
#include <cstdint>

namespace sybl {
// Caller holds its queue mutex. This budget applies only to annotation data;
// call lifecycle, consent and cleanup callbacks must never be discarded here.
class AnnotationIngress {
 public:
  bool Admit(size_t size, uint64_t now_ms) {
    if (size == 0 || size > 65536) return false;
    const auto elapsed = observed_ && now_ms >= last_ ? now_ms - last_ : 0;
    observed_ = true;
    last_ = now_ms;
    messages_ = std::min(128.0, messages_ + static_cast<double>(elapsed) * .064);
    bytes_ = std::min(1048576.0, bytes_ + static_cast<double>(elapsed) * 262.144);
    if (messages_ < 1 || bytes_ < static_cast<double>(size) || queued_messages_ >= 128 ||
        queued_bytes_ + size > 1048576) return false;
    --messages_;
    bytes_ -= static_cast<double>(size);
    ++queued_messages_;
    queued_bytes_ += size;
    return true;
  }
  void Delivered(size_t size) {
    --queued_messages_;
    queued_bytes_ -= size;
  }
 private:
  bool observed_ = false;
  uint64_t last_ = 0;
  double messages_ = 128, bytes_ = 1048576;
  size_t queued_messages_ = 0, queued_bytes_ = 0;
};
}
