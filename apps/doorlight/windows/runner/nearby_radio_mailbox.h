#ifndef RUNNER_NEARBY_RADIO_MAILBOX_H_
#define RUNNER_NEARBY_RADIO_MAILBOX_H_

#include <algorithm>
#include <array>
#include <chrono>
#include <cstdint>
#include <map>
#include <string>
#include <set>
#include <vector>

namespace sybl::nearby_radio {

using Clock = std::chrono::steady_clock;
using Bytes = std::vector<std::uint8_t>;

// Callers serialize access; each remote long read keeps its original frame.
class Mailbox {
 public:
  bool Put(const Bytes& data, bool announcement, Clock::time_point now, bool ping = false) {
    if (data.empty() || data.size() > 508 || (ping && !announcement) || (!announcement && !visible_)) return false;
    if (announcement) visible_ = true;
    const auto sequence = ++sequence_;
    Bytes frame = {static_cast<std::uint8_t>(sequence >> 24),
             static_cast<std::uint8_t>(sequence >> 16),
             static_cast<std::uint8_t>(sequence >> 8),
             static_cast<std::uint8_t>(sequence)};
    frame.insert(frame.end(), data.begin(), data.end());
    if (!ping) values_[announcement ? 0 : 1] = frame;
    if (ping) {
      ping_ = frame;
      ping_until_ = now + std::chrono::seconds(30);
      ping_readers_.clear();
    }
    if (!announcement) event_until_ = now + std::chrono::seconds(4);
    return true;
  }

  void Hide() {
    visible_ = false;
    values_ = {};
    clients_.clear();
    ping_.clear();
    ping_readers_.clear();
  }

  // ATT errors: 0x02 read denied, 0x07 invalid offset, 0x11 insufficient resources.
  std::uint8_t Read(const std::wstring& client, bool announcement,
                    std::uint32_t offset, std::uint32_t length,
                    Clock::time_point now, Bytes& out) {
    out.clear();
    if (!visible_) return 0x02;
    if (now >= ping_until_) { ping_.clear(); ping_readers_.clear(); }
    for (auto it = clients_.begin(); it != clients_.end();) {
      if (now - it->second.touched >= std::chrono::seconds(4)) it = clients_.erase(it);
      else ++it;
    }
    auto it = clients_.find(client);
    if (it == clients_.end()) {
      if (offset != 0) return 0x07;
      if (clients_.size() >= 4) return 0x11;
      it = clients_.emplace(client, Client{}).first;
    }
    auto& snapshot = it->second.frames[announcement ? 0 : 1];
    it->second.completed_ping = false;
    if (offset == 0) {
      snapshot = (!announcement && now >= event_until_) ? Bytes{} : values_[announcement ? 0 : 1];
      if (announcement) {
        it->second.ping_until = {};
        if (!ping_.empty() && ping_readers_.find(client) == ping_readers_.end() && ping_readers_.size() < 64) {
          snapshot = ping_;
          it->second.ping_until = ping_until_;
        }
      }
      if (!announcement) it->second.event_until = event_until_;
    }
    if (!announcement && offset != 0 && now >= it->second.event_until) return 0x07;
    if (announcement && offset != 0 && it->second.ping_until != Clock::time_point{} &&
        now >= it->second.ping_until) return 0x07;
    if (offset > snapshot.size()) return 0x07;
    it->second.touched = now;
    const auto count = std::min<std::size_t>(length, snapshot.size() - offset);
    out.assign(snapshot.begin() + offset, snapshot.begin() + offset + count);
    it->second.completed_ping = announcement && offset + count == snapshot.size() &&
        !ping_.empty() && snapshot == ping_;
    return 0;
  }

  // Only consume after the platform accepted the final response.
  void Served(const std::wstring& client, Clock::time_point now) {
    const auto it = clients_.find(client);
    if (it != clients_.end() && it->second.completed_ping && now < ping_until_ &&
        it->second.frames[0] == ping_ && ping_readers_.size() < 64) {
      ping_readers_.insert(client);
      it->second.completed_ping = false;
    }
  }

 private:
  struct Client {
    std::array<Bytes, 2> frames;
    Clock::time_point touched{};
    Clock::time_point event_until{};
    Clock::time_point ping_until{};
    bool completed_ping = false;
  };
  bool visible_ = false;
  std::uint32_t sequence_ = 0;
  std::array<Bytes, 2> values_;
  Clock::time_point event_until_{};
  Bytes ping_;
  Clock::time_point ping_until_{};
  std::set<std::wstring> ping_readers_;
  std::map<std::wstring, Client> clients_;
};

}  // namespace sybl::nearby_radio
#endif
