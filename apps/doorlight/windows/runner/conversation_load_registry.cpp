#include "conversation_load_registry.h"

#include <utility>

namespace sybl::conversation {

void LoadRegistry::PurgeExpired(TimePoint now) {
  for (auto it = active_.begin(); it != active_.end();) {
    if (now - it->second.registered_at >= kDeadline) {
      it = active_.erase(it);
    } else {
      ++it;
    }
  }
}

bool LoadRegistry::CanStart(TimePoint now) {
  PurgeExpired(now);
  return !exhausted_ && active_.size() < kMaxActiveLoads &&
         remembered_ids_.size() < kMaxRememberedIds;
}

bool LoadRegistry::Register(std::uint32_t id, PendingLoad load,
                            TimePoint now) {
  PurgeExpired(now);
  if (id == 0 || exhausted_) return false;

  if (remembered_ids_.find(id) != remembered_ids_.end()) {
    // A duplicate is indistinguishable from the first request's late callback.
    // Retire the first active request too, so neither can claim that callback.
    active_.erase(id);
    return false;
  }
  if (remembered_ids_.size() >= kMaxRememberedIds) {
    exhausted_ = true;
    active_.clear();
    return false;
  }

  remembered_ids_.insert(id);
  if (active_.size() >= kMaxActiveLoads) return false;
  active_.emplace(id, Entry{std::move(load), now});
  return true;
}

std::optional<PendingLoad> LoadRegistry::Take(std::uint32_t id,
                                              TimePoint now) {
  PurgeExpired(now);
  const auto found = active_.find(id);
  if (found == active_.end()) return std::nullopt;
  auto load = std::move(found->second.load);
  active_.erase(found);
  return load;
}

bool LoadRegistry::CancelChat(std::uint32_t id, TimePoint now) {
  return Cancel(id, LoadKind::kChat, now);
}

bool LoadRegistry::CancelDmTopicState(std::uint32_t id, TimePoint now) {
  return Cancel(id, LoadKind::kDmTopicState, now);
}

bool LoadRegistry::Cancel(std::uint32_t id, LoadKind kind, TimePoint now) {
  PurgeExpired(now);
  const auto found = active_.find(id);
  if (found == active_.end() ||
      found->second.load.kind != kind) {
    return false;
  }
  active_.erase(found);
  return true;
}

// A selected-result load keeps its daemon scan running, so clear and peer
// removal leave it registered and counted until completion or its deadline.
void LoadRegistry::RemovePeer(const std::string& peer_id, TimePoint now) {
  PurgeExpired(now);
  for (auto it = active_.begin(); it != active_.end();) {
    if (it->second.load.peer_id == peer_id &&
        it->second.load.kind != LoadKind::kSearchMessage) {
      it = active_.erase(it);
    } else {
      ++it;
    }
  }
}

void LoadRegistry::ClearActive() {
  for (auto it = active_.begin(); it != active_.end();) {
    if (it->second.load.kind != LoadKind::kSearchMessage) {
      it = active_.erase(it);
    } else {
      ++it;
    }
  }
}

}  // namespace sybl::conversation
