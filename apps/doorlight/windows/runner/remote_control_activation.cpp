#include "remote_control_activation.h"

namespace sybl::remote {

bool ConsentActivation::Begin(std::uint64_t generation) {
  if (generation == 0 || generation_ != 0) return false;
  generation_ = generation;
  abort_reason_ = ActivationAbortReason::kNone;
  return true;
}

bool ConsentActivation::Cancel(ActivationAbortReason reason) {
  if (generation_ == 0 || reason == ActivationAbortReason::kNone ||
      reason == ActivationAbortReason::kSuperseded) {
    return false;
  }
  // The first lifecycle edge owns the causal reason. Later teardown remains
  // idempotent and cannot rewrite the result observed by the UI thread.
  if (abort_reason_ == ActivationAbortReason::kNone)
    abort_reason_ = reason;
  return true;
}

ActivationCommit ConsentActivation::Commit(std::uint64_t generation) {
  if (generation == 0 || generation != generation_)
    return {false, ActivationAbortReason::kSuperseded};
  const auto reason = abort_reason_;
  Clear();
  return {reason == ActivationAbortReason::kNone, reason};
}

void ConsentActivation::Clear() {
  generation_ = 0;
  abort_reason_ = ActivationAbortReason::kNone;
}

bool ConsentActivation::pending() const {
  return generation_ != 0;
}

std::uint64_t ConsentActivation::generation() const {
  return generation_;
}

}  // namespace sybl::remote
