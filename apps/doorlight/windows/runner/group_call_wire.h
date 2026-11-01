#pragma once

#include "friend_routing.h"

#include <algorithm>
#include <cctype>
#include <chrono>
#include <cstddef>
#include <string>
#include <map>
#include <optional>
#include <utility>
#include <vector>

namespace sybl::group_call {

// Caller holds its worker-queue lock. Bursts replace the pending snapshot query;
// only one query is in flight and each next query waits for a short quiet window.
template <typename Request>
class ConferenceInfoIngress {
 public:
  using Clock = std::chrono::steady_clock;
  using TimePoint = Clock::time_point;
  static constexpr auto kDelay = std::chrono::milliseconds(100);

  void Offer(Request request, TimePoint now) {
    latest_ = std::move(request);
    if (!in_flight_ && !due_) due_ = now + kDelay;
  }

  std::optional<TimePoint> Due() const { return due_; }

  bool Ready(TimePoint now) const {
    return !in_flight_ && latest_.has_value() && due_ && now >= *due_;
  }

  std::optional<Request> Take(TimePoint now) {
    if (!Ready(now)) return std::nullopt;
    auto result = std::move(latest_);
    latest_.reset();
    due_.reset();
    in_flight_ = true;
    return result;
  }

  void Finish(TimePoint now) {
    in_flight_ = false;
    if (latest_) due_ = now + kDelay;
  }

  void Clear() {
    latest_.reset();
    due_.reset();
    in_flight_ = false;
  }

 private:
  std::optional<Request> latest_;
  std::optional<TimePoint> due_;
  bool in_flight_ = false;
};

inline bool ConferenceInfoWithinBounds(
    const std::vector<std::map<std::string, std::string>>& infos) {
  if (infos.size() > 128) return false;
  size_t bytes = 0;
  for (const auto& info : infos) {
    if (info.size() > 32) return false;
    for (const auto& entry : info) {
      if (entry.first.size() > 1024 || entry.second.size() > 1024) return false;
      bytes += entry.first.size() + entry.second.size();
      if (bytes > 64 * 1024) return false;
    }
  }
  return true;
}

inline constexpr char kPresenceMime[] =
    "application/x-sybl-group-call-presence+json";
inline constexpr size_t kMaxPresenceBytes = 2048;

inline std::string RoomId(const std::string& conference_id) {
  constexpr char prefix[] = "syblv1-";
  if (conference_id.compare(0, sizeof(prefix) - 1, prefix) != 0) return {};
  const auto suffix = conference_id.rfind('-');
  if (suffix <= sizeof(prefix) - 1 || suffix + 1 >= conference_id.size()) {
    return {};
  }
  const auto room = conference_id.substr(sizeof(prefix) - 1,
                                         suffix - (sizeof(prefix) - 1));
  if (room.empty() || room.size() > 32 ||
      (!std::islower(static_cast<unsigned char>(room.front())) &&
       !std::isdigit(static_cast<unsigned char>(room.front()))) ||
      !std::all_of(room.begin(), room.end(), [](unsigned char value) {
        return std::islower(value) || std::isdigit(value) || value == '-';
      })) {
    return {};
  }
  const auto digits = conference_id.substr(suffix + 1);
  if (digits.size() > 20 || digits.front() == '0' ||
      !std::all_of(digits.begin(), digits.end(),
                   [](unsigned char value) { return std::isdigit(value); })) {
    return {};
  }
  return room;
}

inline std::string MediaTarget(const std::string& conference_id,
                               const std::string& call_leg, bool hosting) {
  return hosting || call_leg.empty() ? conference_id : call_leg;
}

inline bool OwnsMediaSink(const std::string& owner,
                          const std::string& call_leg,
                          const std::string& sink_id) {
  return !owner.empty() &&
         (sink_id == owner || (!call_leg.empty() && sink_id == call_leg));
}

inline std::string HostConferenceForCurrent(
    const std::string& conference_id, bool hosting, bool rejected,
    const std::string& state) {
  return hosting && !rejected && state == "CURRENT" ? conference_id
                                                      : std::string{};
}

inline bool AcceptPresence(const routing::RoutingSnapshot& snapshot,
                           const std::string& raw_sender,
                           const std::string& body) {
  if (body.size() > kMaxPresenceBytes) return false;
  const auto sender = routing::BareJamiId(raw_sender);
  if (sender.empty()) return false;
  return std::any_of(snapshot.groups.begin(), snapshot.groups.end(),
                     [&](const auto& entry) {
    return entry.second.active_member_ids.find(sender) !=
           entry.second.active_member_ids.end();
  });
}

}  // namespace sybl::group_call
