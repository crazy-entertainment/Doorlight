#pragma once

#include <cstdint>

namespace sybl::remote {

enum class ActivationAbortReason {
  kNone,
  kLocalStop,
  kCallEnded,
  kSourceChanged,
  kShutdown,
  kSuperseded,
};

struct ActivationCommit {
  bool current = false;
  ActivationAbortReason reason = ActivationAbortReason::kSuperseded;
};

// Small, lock-free state machine used under RemoteControlHost::mutex_. It
// makes the local-consent -> Win32-runtime activation race explicit and keeps
// its generation/cancellation rules independently mutation-testable.
class ConsentActivation {
 public:
  bool Begin(std::uint64_t generation);
  bool Cancel(ActivationAbortReason reason);
  ActivationCommit Commit(std::uint64_t generation);
  void Clear();
  bool pending() const;
  std::uint64_t generation() const;

 private:
  std::uint64_t generation_ = 0;
  ActivationAbortReason abort_reason_ = ActivationAbortReason::kNone;
};

}  // namespace sybl::remote
