#pragma once

#include <chrono>
#include <cstddef>
#include <cstdint>
#include <optional>
#include <string>
#include <unordered_map>
#include <unordered_set>
#include <utility>
#include <vector>

namespace sybl::conversation {

enum class LoadKind { kFolder, kChat, kDmTopicState, kSearchMessage };

struct PendingLoad {
  LoadKind kind;
  std::string peer_id;
  std::string conversation_id;
  std::string cursor;
  int limit;
};

// libjami returns a random process-wide uint32 id and exposes no cancellation
// token beyond that id. Consequently a completed/cancelled id must never be
// accepted again in this process: otherwise an arbitrarily late callback could
// claim a newer request with the same id. Remembered ids are bounded; once the
// budget is exhausted the registry fails closed instead of recycling identity.
class LoadRegistry {
 public:
  using Clock = std::chrono::steady_clock;
  using TimePoint = Clock::time_point;

  static constexpr auto kDeadline = std::chrono::seconds(35);
  static constexpr std::size_t kMaxActiveLoads = 64;
  static constexpr std::size_t kMaxRememberedIds = 64 * 1024;

  bool CanStart(TimePoint now = Clock::now());
  bool Register(std::uint32_t id, PendingLoad load,
                TimePoint now = Clock::now());
  std::optional<PendingLoad> Take(std::uint32_t id,
                                  TimePoint now = Clock::now());
  bool CancelChat(std::uint32_t id, TimePoint now = Clock::now());
  bool CancelDmTopicState(std::uint32_t id, TimePoint now = Clock::now());
  void RemovePeer(const std::string& peer_id,
                  TimePoint now = Clock::now());
  void ClearActive();
  void Expire(TimePoint now) { PurgeExpired(now); }
  bool Active(std::uint32_t id) const { return active_.count(id) != 0; }

  std::size_t active_size() const { return active_.size(); }
  std::size_t remembered_size() const { return remembered_ids_.size(); }

 private:
  struct Entry {
    PendingLoad load;
    TimePoint registered_at;
  };

  void PurgeExpired(TimePoint now);
  bool Cancel(std::uint32_t id, LoadKind kind, TimePoint now);

  std::unordered_map<std::uint32_t, Entry> active_;
  std::unordered_set<std::uint32_t> remembered_ids_;
  bool exhausted_ = false;
};

// A load whose caller must be answered exactly once keeps that caller here,
// beside its registry entry and under the same id. The caller leaves only by
// Complete (the daemon answered the taken load) or by Retired, once the
// registry no longer holds the load: expiry, duplicate id or exhaustion.
// Clear and peer removal keep it. Retired callers are answered unavailable.
template <class Request>
class AnsweredLoads {
 public:
  using TimePoint = LoadRegistry::TimePoint;

  bool Register(LoadRegistry& registry, std::uint32_t id, PendingLoad load,
                Request request, TimePoint now = LoadRegistry::Clock::now()) {
    if (!registry.Register(id, std::move(load), now)) return false;
    entries_.emplace(id, Entry{std::move(request), now});
    return true;
  }
  std::optional<Request> Complete(std::uint32_t id) {
    const auto found = entries_.find(id);
    if (found == entries_.end()) return std::nullopt;
    auto request = std::move(found->second.request);
    entries_.erase(found);
    return request;
  }
  std::vector<Request> Retired(LoadRegistry& registry, TimePoint now) {
    registry.Expire(now);
    std::vector<Request> retired;
    for (auto it = entries_.begin(); it != entries_.end();) {
      if (registry.Active(it->first)) {
        ++it;
        continue;
      }
      retired.push_back(std::move(it->second.request));
      it = entries_.erase(it);
    }
    return retired;
  }
  // When Retired next has work: at once for a load the registry already
  // dropped, otherwise the earliest deadline.
  std::optional<TimePoint> Due(const LoadRegistry& registry) const {
    std::optional<TimePoint> due;
    for (const auto& entry : entries_) {
      const auto at = registry.Active(entry.first)
                          ? entry.second.registered_at + LoadRegistry::kDeadline
                          : TimePoint::min();
      if (!due || at < *due) due = at;
    }
    return due;
  }
  std::vector<Request> TakeAll() {
    std::vector<Request> all;
    for (auto& entry : entries_) all.push_back(std::move(entry.second.request));
    entries_.clear();
    return all;
  }

  std::size_t size() const { return entries_.size(); }

 private:
  struct Entry {
    Request request;
    TimePoint registered_at;
  };

  std::unordered_map<std::uint32_t, Entry> entries_;
};

}  // namespace sybl::conversation
