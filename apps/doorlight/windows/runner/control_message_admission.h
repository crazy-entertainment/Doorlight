#pragma once

#include "remote_control_protocol.h"
#include <algorithm>
#include <cstdint>
#include <map>
#include <string>
#include <tuple>

namespace sybl::remote {
// Caller owns synchronization; hostile identities cannot grow the table.
class ControlMessageAdmission {
 public:
  bool Admit(const std::string& account, const std::string& call,
             const std::string& peer, std::size_t bytes, std::uint64_t now) {
    if (!bytes || bytes > kMaxPacketBytes || account.empty() || call.empty() || peer.empty() ||
        account.size() > 256 || call.size() > 256 || peer.size() > 256) return false;
    Refill(total_, now);
    if (total_.tokens < 1) return false;
    for (auto it = peers_.begin(); it != peers_.end();) {
      if (now >= it->second.at && now - it->second.at > 60000) it = peers_.erase(it);
      else ++it;
    }
    const auto key = std::make_tuple(account, call, peer);
    auto it = peers_.find(key);
    if (it == peers_.end()) {
      if (peers_.size() >= 32) return false;
      it = peers_.emplace(key, Bucket{now, 64}).first;
    }
    Refill(it->second, now);
    if (it->second.tokens < 1) return false;
    --it->second.tokens;
    --total_.tokens;
    return true;
  }
 private:
  struct Bucket { std::uint64_t at; double tokens; };
  static void Refill(Bucket& bucket, std::uint64_t now) {
    const auto elapsed = now >= bucket.at ? now - bucket.at : 0;
    bucket.tokens = std::min(128.0, bucket.tokens + elapsed * .320);
    bucket.at = now;
  }
  Bucket total_{0, 128};
  std::map<std::tuple<std::string, std::string, std::string>, Bucket> peers_;
};
}  // namespace sybl::remote
