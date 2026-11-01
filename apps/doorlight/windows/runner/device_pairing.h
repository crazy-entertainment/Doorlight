#pragma once

#include <algorithm>
#include <cstdint>
#include <deque>
#include <limits>
#include <set>
#include <map>
#include <mutex>
#include <string>

namespace sybl::device_pairing {
inline bool Hex(const std::string& value, size_t length) {
  return value.size() == length && std::all_of(value.begin(), value.end(), [](char c) {
    return (c >= '0' && c <= '9') || (c >= 'a' && c <= 'f');
  });
}
inline bool Digits(const std::string& value, size_t length) {
  return value.size() == length && std::all_of(value.begin(), value.end(), [](char c) { return c >= '0' && c <= '9'; });
}
inline bool ValidOffer(const std::string& value) {
  const std::string prefix = "jami-auth://", suffix = "/doorlight-v1";
  return value.size() == prefix.size() + 64 + 1 + 6 + suffix.size() &&
      value.compare(0, prefix.size(), prefix) == 0 && Hex(value.substr(prefix.size(), 64), 64) &&
      value[prefix.size() + 64] == '/' && value[prefix.size() + 65] != '0' &&
      Digits(value.substr(prefix.size() + 65, 6), 6) &&
      value.compare(value.size() - suffix.size(), suffix.size(), suffix) == 0;
}
inline bool ValidCode(const std::string& value) { return Digits(value, 8); }

class Visits {
 public:
  uint64_t Capture() const { std::lock_guard<std::mutex> lock(mutex_); return generation_; }
  bool Allows(const std::string& token, uint64_t epoch) const {
    std::lock_guard<std::mutex> lock(mutex_);
    return generation_ != std::numeric_limits<uint64_t>::max() && generation_ == epoch &&
        Hex(token, 64) && !retired_.count(token);
  }
  void Retire(const std::string& token) {
    std::lock_guard<std::mutex> lock(mutex_);
    if (!Hex(token, 64) || !retired_.insert(token).second) return;
    order_.push_back(token);
    if (order_.size() > 64) { retired_.erase(order_.front()); order_.pop_front(); }
  }
  void RetireAll() {
    std::lock_guard<std::mutex> lock(mutex_);
    if (generation_ != std::numeric_limits<uint64_t>::max()) ++generation_;
  }
 private:
  mutable std::mutex mutex_;
  uint64_t generation_ = 0;
  std::set<std::string> retired_;
  std::deque<std::string> order_;
};

struct Snapshot {
  std::string token, account, status = "starting", uri, code, peer, peer_device, device, error;
  uint32_t operation = 0;
  bool destination = false, terminal = false, invalid_code = false;
};

// One process-local protocol projection. The host owns the selected-account
// lease and the durable destination journal. No archive credentials enter here.
class Flow {
 public:
  Flow(std::string token, std::string account, bool destination) {
    value_.token = std::move(token); value_.account = std::move(account); value_.destination = destination;
  }
  bool BindOperation(uint32_t operation) {
    std::lock_guard<std::mutex> lock(mutex_);
    if (operation == 0 || operation > INT32_MAX ||
        (value_.destination && (operation < 100000 || operation > 999999)) ||
        (value_.operation != 0 && value_.operation != operation)) return false;
    value_.operation = operation; return true;
  }
  bool Accept(uint32_t operation, int state, const std::map<std::string, std::string>& details) {
    std::lock_guard<std::mutex> lock(mutex_);
    if (value_.terminal || value_.operation == 0 || operation != value_.operation || state < 1 || state > 5) return false;
    const auto get = [&](const char* key) {
      const auto found = details.find(key); return found == details.end() ? std::string{} : found->second;
    };
    if (state == 5) {
      if (!details.count("error") || get("error").size() > 64) return false;
      const auto error = get("error");
      if (error.empty() && !Identities(details, true)) return false;
      value_.terminal = true; native_succeeded_ = error.empty();
      value_.error = error.empty() || error == "canceled" || error == "timeout" || error == "auth_error" ||
          error == "network" || error == "source_disabled" ? error : "unavailable";
      value_.status = native_succeeded_ ? (value_.destination ? "confirming" : "complete") : "ended";
      value_.uri.clear(); value_.code.clear(); return true;
    }
    if (retired_) return false;
    if (value_.destination) {
      if (state == 1) {
        if (value_.status != "starting" || !ValidOffer(get("token")) ||
            get("operation") != std::to_string(operation) || get("auth_scheme") != "doorlight-code-v1") return false;
        value_.uri = get("token"); value_.status = "waiting";
      } else if (state == 3) {
        if ((value_.status != "waiting" && value_.status != "checking" && value_.status != "code" && value_.status != "unconfirmed") ||
            get("auth_scheme") != "doorlight-code-v1" || !Identities(details, false)) return false;
        value_.status = "code"; value_.invalid_code = get("auth_error") == "invalid_code";
      } else if (state == 4) {
        if ((value_.status != "checking" && value_.status != "code" && value_.status != "unconfirmed") ||
            get("prepared") != "true" || !Identities(details, true)) return false;
        value_.status = "prepared"; value_.uri.clear(); value_.code.clear(); value_.invalid_code = false;
      } else return false;
    } else {
      if (state == 2) {
        if (value_.status != "starting") return false;
        value_.status = "connecting";
      } else if (state == 3) {
        if ((value_.status != "starting" && value_.status != "connecting") || get("auth_scheme") != "doorlight-code-v1") return false;
        value_.status = "consent";
      } else if (state == 4) {
        if (value_.status != "codeIssued" && value_.status != "unconfirmed") return false;
        value_.status = "transferring"; value_.code.clear();
      }
      else return false;
    }
    return true;
  }
  bool IssuedCode(const std::string& code) {
    std::lock_guard<std::mutex> lock(mutex_);
    if (value_.destination || retired_ || value_.terminal || value_.status != "consent" || !ValidCode(code)) return false;
    value_.code = code; value_.status = "codeIssued"; return true;
  }
  bool SubmittingCode() {
    std::lock_guard<std::mutex> lock(mutex_);
    if (!value_.destination || retired_ || value_.terminal || value_.status != "code") return false;
    value_.status = "checking"; value_.invalid_code = false; return true;
  }
  bool PreparedPrivacy() {
    std::lock_guard<std::mutex> lock(mutex_);
    if (!value_.destination || retired_ || value_.terminal || value_.status != "prepared") return false;
    privacy_committed_ = true; value_.status = "confirming"; return true;
  }
  bool AcknowledgedDurably() {
    std::lock_guard<std::mutex> lock(mutex_);
    if (!value_.destination || !native_succeeded_ || !privacy_committed_) return false;
    value_.status = "ready"; return true;
  }
  void Unconfirmed() {
    std::lock_guard<std::mutex> lock(mutex_);
    if (!value_.terminal || (value_.destination && value_.status != "ready")) value_.status = "unconfirmed";
    value_.code.clear();
  }
  void Retire() {
    std::lock_guard<std::mutex> lock(mutex_);
    retired_ = true; value_.uri.clear(); value_.code.clear();
  }
  Snapshot snapshot() const {
    std::lock_guard<std::mutex> lock(mutex_);
    auto result = value_;
    if (retired_) {
      result.status = "retired"; result.uri.clear(); result.code.clear();
      result.peer.clear(); result.peer_device.clear(); result.device.clear(); result.invalid_code = false;
    }
    return result;
  }
  bool native_succeeded() const { std::lock_guard<std::mutex> lock(mutex_); return native_succeeded_; }
  bool privacy_committed() const { std::lock_guard<std::mutex> lock(mutex_); return privacy_committed_; }
  bool retired() const { std::lock_guard<std::mutex> lock(mutex_); return retired_; }

 private:
  bool Identities(const std::map<std::string, std::string>& details, bool prepared) {
    const auto get = [&](const char* key) {
      const auto found = details.find(key); return found == details.end() ? std::string{} : found->second;
    };
    const auto peer = get("peer_id"), source = get("peer_device"), device = get("device_id");
    if (!Hex(peer, 40) || !Hex(source, 64) || (prepared && (!Hex(device, 64) || device == source)) ||
        (!value_.peer.empty() && value_.peer != peer) || (!value_.peer_device.empty() && value_.peer_device != source) ||
        (!value_.device.empty() && prepared && value_.device != device)) return false;
    value_.peer = peer; value_.peer_device = source;
    if (prepared) value_.device = device;
    return true;
  }
  mutable std::mutex mutex_;
  Snapshot value_;
  bool retired_ = false, native_succeeded_ = false, privacy_committed_ = false;
};
}  // namespace sybl::device_pairing
