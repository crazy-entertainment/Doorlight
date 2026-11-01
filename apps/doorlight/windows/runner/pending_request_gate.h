#pragma once

#include <cstddef>
#include <cstdint>
#include <deque>
#include <set>
#include <string>

namespace sybl {

enum class PendingRequestAdmission { kNew, kDuplicate, kRejected };

class PendingRequestGate {
 public:
  explicit PendingRequestGate(std::size_t max_pending = 64,
                              std::size_t max_per_window = 16,
                              std::int64_t window_ms = 60000)
      : max_pending_(max_pending),
        max_per_window_(max_per_window),
        window_ms_(window_ms) {}

  PendingRequestAdmission Admit(const std::string& id, std::int64_t now_ms) {
    if (ids_.find(id) != ids_.end()) return PendingRequestAdmission::kDuplicate;
    while (!admitted_at_.empty() && now_ms - admitted_at_.front() >= window_ms_)
      admitted_at_.pop_front();
    if (ids_.size() >= max_pending_ || admitted_at_.size() >= max_per_window_)
      return PendingRequestAdmission::kRejected;
    ids_.insert(id);
    admitted_at_.push_back(now_ms);
    return PendingRequestAdmission::kNew;
  }

  bool Remove(const std::string& id) { return ids_.erase(id) != 0; }
  bool Contains(const std::string& id) const {
    return ids_.find(id) != ids_.end();
  }
  bool Restore(const std::string& id) {
    return ids_.find(id) != ids_.end() ||
           (ids_.size() < max_pending_ && ids_.insert(id).second);
  }
  void Clear() {
    ids_.clear();
    admitted_at_.clear();
  }

 private:
  std::size_t max_pending_;
  std::size_t max_per_window_;
  std::int64_t window_ms_;
  std::set<std::string> ids_;
  std::deque<std::int64_t> admitted_at_;
};

}  // namespace sybl
