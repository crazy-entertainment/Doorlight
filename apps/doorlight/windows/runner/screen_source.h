#pragma once

#include <cstddef>
#include <cstdint>
#include <optional>
#include <string>
#include <utility>
#include <vector>

namespace screen_source {

enum class Kind { Off, Camera, Screen };

struct Monitor {
  int index = -1;
  // Opaque topology-bound identity exposed to Dart. The daemon still needs [index]
  // for its dxgigrab MRL, but callers must never persist/replay that transient index.
  std::string id;
  std::string label;
  bool primary = false;
  int left = 0;
  int top = 0;
  int width = 0;
  int height = 0;
};

struct Outgoing {
  Kind kind = Kind::Off;
  std::string uri;
  std::string call_id;
  std::uint64_t epoch = 0;
  int width = 0;
  int height = 0;
};

struct Transition {
  Outgoing previous;
  Outgoing requested;
};

struct CaptureProof {
  std::string uri;
  std::string call_id;
  std::uint64_t epoch = 0;
  bool frame_published = false;
};

// Holds the one pending transition and the ticket of the invocation that admitted it. Only the
// holder of that ticket may take the value; an invocation that was never admitted (or whose
// transition already ended) holds no valid ticket. Daemon-event and call-end completions carry
// no ticket, so they read and clear the current value through the pointer-style accessors.
// No mutex of its own: callers serialize access.
template <typename T>
class TransitionSlot {
 public:
  // Not copyable or assignable: `slot = {}` would clear the pending value without a ticket and
  // reset the ticket counter, making an old ticket valid again.
  TransitionSlot() = default;
  TransitionSlot(const TransitionSlot&) = delete;
  TransitionSlot& operator=(const TransitionSlot&) = delete;
  TransitionSlot& operator=(TransitionSlot&&) = delete;

  // Returns the new ticket, or 0 when busy. [value] is only moved from on admission.
  std::uint64_t Admit(T&& value) {
    if (pending_) return 0;
    pending_ = std::move(value);
    active_ = ++issued_;
    return active_;
  }
  std::optional<T> Take(std::uint64_t ticket) {
    if (!pending_ || ticket == 0 || ticket != active_) return std::nullopt;
    std::optional<T> taken = std::move(pending_);
    pending_.reset();
    return taken;
  }
  explicit operator bool() const { return pending_.has_value(); }
  T* operator->() { return &*pending_; }
  T& operator*() { return *pending_; }
  void reset() { pending_.reset(); }

 private:
  std::optional<T> pending_;
  std::uint64_t issued_ = 0;
  std::uint64_t active_ = 0;
};

Kind Classify(const std::string& uri);
std::string KindName(Kind kind);
std::optional<std::string> DisplayMrl(const Monitor& monitor);
const Monitor* FindMonitor(const std::vector<Monitor>& monitors, const std::string& source_id);
bool AcceptsCompletion(const Outgoing& current, const std::string& call_id, std::uint64_t epoch);
bool OwnsCaptureProof(const Outgoing& current,
                      const std::string& active_call_id,
                      const CaptureProof& proof);
bool OwnsTransition(const Outgoing& current, const std::string& active_call_id,
                    const Transition& transition);
Outgoing ResolveTransition(const Outgoing& current, const std::string& active_call_id,
                           const Transition& transition, bool accepted);
struct CancelledTransition {
  Outgoing source;
  std::size_t camera_index = 0;
};
// A transition cancelled without a confirmed outcome was never adopted: when it still owns
// [current], return its previous source (newer epoch) and camera index; otherwise leave both.
CancelledTransition CancelTransition(const Outgoing& current, std::size_t current_camera_index,
                                     const Transition& transition,
                                     std::size_t previous_camera_index);
bool ShouldReassertAfterPeerAnswer(const Outgoing& current,
                                   const std::string& active_call_id,
                                   const std::string& negotiated_call_id,
                                   bool follows_peer_answer,
                                   bool negotiation_matches);

}  // namespace screen_source
