#pragma once

#include <algorithm>
#include <cstdint>
#include <functional>
#include <future>
#include <memory>
#include <mutex>
#include <string>
#include <utility>

namespace record_windows {

// Owned by the native host. Never treat an expired wait as device release.
class NativeRecordingLease {
  struct CallbackLifetime {
    std::mutex mutex;
    NativeRecordingLease* owner = nullptr;
  };
 public:
  using Completion = std::function<void(bool)>;
  using Stop = std::function<void(Completion)>;
  struct Ticket {
    const uint64_t owner;
    const std::string recorder_id;
    const uint64_t started;
    uint64_t deadline;
    const Stop stop;
    bool revoked = false;
    bool stop_requested = false;
    bool completion_observed = false;
    std::promise<bool> completion;
    std::shared_future<bool> released;

    Ticket(uint64_t owner_value, std::string recorder, uint64_t now, Stop stop_fn)
        : owner(owner_value), recorder_id(std::move(recorder)), started(now),
          deadline(now + 2000), stop(std::move(stop_fn)),
          released(completion.get_future().share()) {}
  };
  using Lease = std::shared_ptr<Ticket>;

  NativeRecordingLease(std::function<uint64_t()> clock,
                       std::function<bool(uint64_t)> owner_current)
      : clock_(std::move(clock)), owner_current_(std::move(owner_current)) {
    callback_lifetime_->owner = this;
  }

  ~NativeRecordingLease() {
    Revoke();
    std::lock_guard<std::mutex> guard(callback_lifetime_->mutex);
    callback_lifetime_->owner = nullptr;
  }

  Lease Begin(uint64_t owner, std::string recorder, Stop stop) {
    std::lock_guard<std::mutex> guard(mutex_);
    if (!foreground_ || call_blocked_ || active_ || !owner_current_(owner) ||
        recorder.empty() || recorder.size() > 128 || !stop) return {};
    active_ = std::make_shared<Ticket>(owner, std::move(recorder), clock_(), std::move(stop));
    return active_;
  }

  bool Current(const Lease& lease) const {
    std::lock_guard<std::mutex> guard(mutex_);
    return CurrentLocked(lease);
  }

  bool Renew(const Lease& lease) {
    std::lock_guard<std::mutex> guard(mutex_);
    if (!CurrentLocked(lease)) return false;
    lease->deadline = (std::min)(clock_() + 2000, lease->started + 120000);
    return true;
  }

  bool Occupied() const {
    std::lock_guard<std::mutex> guard(mutex_);
    return active_ != nullptr;
  }

  void SetForeground(bool foreground) {
    { std::lock_guard<std::mutex> guard(mutex_); foreground_ = foreground; }
    if (!foreground) Revoke();
  }

  std::shared_future<bool> BlockForCall() {
    { std::lock_guard<std::mutex> guard(mutex_); call_blocked_ = true; }
    return Revoke();
  }

  void ClearCallBlock() {
    std::lock_guard<std::mutex> guard(mutex_);
    call_blocked_ = false;
  }

  void Tick() {
    Lease expired;
    {
      std::lock_guard<std::mutex> guard(mutex_);
      if (active_ && !CurrentLocked(active_)) expired = active_;
    }
    if (expired) Revoke(expired);
  }

  std::shared_future<bool> Revoke() {
    Lease lease;
    { std::lock_guard<std::mutex> guard(mutex_); lease = active_; }
    if (lease) return Revoke(lease);
    std::promise<bool> idle;
    idle.set_value(true);
    return idle.get_future().share();
  }

  void Released(const Lease& lease, bool success) {
    {
      std::lock_guard<std::mutex> guard(mutex_);
      if (!lease || active_ != lease || lease->completion_observed) return;
      lease->completion_observed = true;
      lease->revoked = true;
      if (success) active_.reset();
    }
    lease->completion.set_value(success);
  }

 private:
  bool CurrentLocked(const Lease& lease) const {
    const auto now = clock_();
    return lease && active_ == lease && !lease->revoked && foreground_ &&
           !call_blocked_ && now >= lease->started && now < lease->deadline &&
           now - lease->started < 120000 && owner_current_(lease->owner);
  }

  std::shared_future<bool> Revoke(const Lease& lease) {
    bool stop = false;
    {
      std::lock_guard<std::mutex> guard(mutex_);
      if (active_ != lease) return lease->released;
      lease->revoked = true;
      if (!lease->stop_requested && !lease->completion_observed) {
        lease->stop_requested = true;
        stop = true;
      }
    }
    if (stop) {
      const auto lifetime = callback_lifetime_;
      try { lease->stop([lifetime, lease](bool success) {
        std::lock_guard<std::mutex> guard(lifetime->mutex);
        if (lifetime->owner) lifetime->owner->Released(lease, success);
      }); }
      catch (...) { Released(lease, false); }
    }
    return lease->released;
  }

  const std::function<uint64_t()> clock_;
  const std::shared_ptr<CallbackLifetime> callback_lifetime_ = std::make_shared<CallbackLifetime>();
  const std::function<bool(uint64_t)> owner_current_;
  mutable std::mutex mutex_;
  Lease active_;
  bool foreground_ = false;
  bool call_blocked_ = false;
};
}  // namespace record_windows
