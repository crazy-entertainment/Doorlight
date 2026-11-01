#include "screen_source.h"

namespace screen_source {

Kind Classify(const std::string& uri) {
  if (uri.rfind("display://", 0) == 0 || uri == "camera://desktop") return Kind::Screen;
  if (uri.rfind("camera://", 0) == 0) return Kind::Camera;
  return Kind::Off;
}

std::string KindName(Kind kind) {
  switch (kind) {
    case Kind::Camera:
      return "camera";
    case Kind::Screen:
      return "screen";
    default:
      return "off";
  }
}

std::optional<std::string> DisplayMrl(const Monitor& monitor) {
  if (monitor.index < 0 || monitor.width <= 0 || monitor.height <= 0) return std::nullopt;
  return "display://:" + std::to_string(monitor.index) + "+0,0 " +
      std::to_string(monitor.width) + "x" + std::to_string(monitor.height);
}

const Monitor* FindMonitor(const std::vector<Monitor>& monitors, const std::string& source_id) {
  if (source_id.empty()) return nullptr;
  for (const auto& monitor : monitors) {
    if (monitor.id == source_id && monitor.width > 0 && monitor.height > 0) return &monitor;
  }
  return nullptr;
}

bool AcceptsCompletion(const Outgoing& current, const std::string& call_id, std::uint64_t epoch) {
  return !call_id.empty() && current.call_id == call_id && current.epoch == epoch;
}

bool OwnsCaptureProof(const Outgoing& current,
                      const std::string& active_call_id,
                      const CaptureProof& proof) {
  return proof.frame_published && current.kind == Kind::Screen &&
      !current.uri.empty() && current.uri == proof.uri &&
      current.call_id == active_call_id &&
      AcceptsCompletion(current, proof.call_id, proof.epoch);
}

bool OwnsTransition(const Outgoing& current, const std::string& active_call_id,
                    const Transition& transition) {
  return active_call_id == transition.requested.call_id &&
      AcceptsCompletion(current, transition.requested.call_id, transition.requested.epoch) &&
      current.kind == transition.requested.kind && current.uri == transition.requested.uri;
}

Outgoing ResolveTransition(const Outgoing& current, const std::string& active_call_id,
                           const Transition& transition, bool accepted) {
  if (!OwnsTransition(current, active_call_id, transition)) return current;
  if (accepted) return transition.requested;
  Outgoing rolled_back = transition.previous;
  // Native revisions are monotonic truth tokens. A rejected optimistic source
  // may already have escaped in a concurrent call snapshot, so restoring the
  // older epoch would make Dart correctly reject the rollback as stale.
  rolled_back.call_id = transition.requested.call_id;
  rolled_back.epoch = transition.requested.epoch + 1;
  return rolled_back;
}

CancelledTransition CancelTransition(const Outgoing& current, std::size_t current_camera_index,
                                     const Transition& transition,
                                     std::size_t previous_camera_index) {
  // Ownership is judged against the transition's own call: the cancel happens because the
  // active target is moving or gone, and the rollback must land before anything reassigns it.
  const std::string& owner = transition.requested.call_id;
  if (!OwnsTransition(current, owner, transition)) return {current, current_camera_index};
  return {ResolveTransition(current, owner, transition, false), previous_camera_index};
}

bool ShouldReassertAfterPeerAnswer(const Outgoing& current,
                                   const std::string& active_call_id,
                                   const std::string& negotiated_call_id,
                                   bool follows_peer_answer,
                                   bool negotiation_matches) {
  return follows_peer_answer && !negotiation_matches &&
      current.kind != Kind::Off && !current.uri.empty() &&
      !negotiated_call_id.empty() &&
      current.call_id == negotiated_call_id &&
      active_call_id == negotiated_call_id;
}

}  // namespace screen_source
