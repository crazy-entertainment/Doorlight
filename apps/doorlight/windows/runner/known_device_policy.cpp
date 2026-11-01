#include "known_device_policy.h"

#include "timeline_wire.h"

#include <algorithm>
#include <limits>

namespace sybl::known_device {

bool IsDeviceId(std::string_view value) {
  if (value.size() < 40 || value.size() > 128) return false;
  return std::all_of(value.begin(), value.end(), [](unsigned char value) {
    return (value >= '0' && value <= '9') ||
           (value >= 'a' && value <= 'f');
  });
}

std::string BoundedName(std::string_view value) {
  while (!value.empty() && value.front() == ' ') value.remove_prefix(1);
  while (!value.empty() && value.back() == ' ') value.remove_suffix(1);
  if (value.size() > kMaxNameUtf8Bytes ||
      !sybl::timeline::MeasureUtf8(value, kMaxNameUtf8Bytes).has_value()) {
    return {};
  }
  for (const auto byte : value) {
    const auto character = static_cast<unsigned char>(byte);
    if (character < 0x20u || character == 0x7fu) return {};
  }
  return std::string(value);
}

std::vector<Device> Project(
    const std::map<std::string, std::string>& known,
    std::string_view current_id) {
  std::vector<Device> result;
  result.reserve(std::min(known.size(), kMaxDevices));
  const auto append = [&result, current_id](const auto& entry) {
    if (result.size() >= kMaxDevices || !IsDeviceId(entry.first)) return;
    result.push_back(
        Device{entry.first, BoundedName(entry.second), entry.first == current_id});
  };
  if (const auto current = known.find(std::string(current_id));
      current != known.end()) {
    append(*current);
  }
  for (const auto& entry : known) {
    if (entry.first != current_id) append(entry);
    if (result.size() >= kMaxDevices) break;
  }
  return result;
}

bool CanRevoke(std::string_view requested_id, std::string_view current_id,
               const std::map<std::string, std::string>& known) {
  return IsDeviceId(requested_id) && IsDeviceId(current_id) &&
         requested_id != current_id &&
         known.find(std::string(requested_id)) != known.end();
}

const char* RevocationStatusName(RevocationStatus status) {
  switch (status) {
    case RevocationStatus::kRevoked: return "revoked";
    case RevocationStatus::kCredentials: return "credentials";
    case RevocationStatus::kNetwork: return "network";
    case RevocationStatus::kTimeout: return "timeout";
    case RevocationStatus::kPending: return "pending";
    case RevocationStatus::kRefused: return "refused";
    case RevocationStatus::kAccountChanged: return "account-changed";
    case RevocationStatus::kUnavailable: return "unavailable";
  }
  return "unavailable";
}

void RevocationRegistry::SelectAccount(const std::string& account_id) {
  std::lock_guard lock(mutex_);
  if (account_id_ == account_id) return;
  account_id_ = account_id;
  for (auto& [key, entry] : entries_) {
    if (!entry.outcome) entry.outcome = RevocationStatus::kAccountChanged;
  }
}

RevocationRegistry::Admission RevocationRegistry::Begin(
    const std::string& account_id, const std::string& device_id,
    std::uint64_t now_ms, Reply reply) {
  std::lock_guard lock(mutex_);
  if (closed_) return {};
  if (account_id.empty() || account_id != account_id_)
    return {0, RevocationStatus::kAccountChanged};
  if (!IsDeviceId(device_id)) return {0, RevocationStatus::kRefused};
  if (entries_.size() >= kMaxDevices || entries_.count({account_id, device_id}))
    return {0, RevocationStatus::kPending};
  if (next_ticket_ == std::numeric_limits<std::uint64_t>::max() ||
      now_ms > std::numeric_limits<std::uint64_t>::max() - kTimeoutMs) return {};
  const auto ticket = ++next_ticket_;
  entries_.emplace(std::make_pair(account_id, device_id),
                   Entry{ticket, now_ms + kTimeoutMs, std::move(reply)});
  return {ticket, RevocationStatus::kPending};
}

bool RevocationRegistry::Pending(std::uint64_t ticket) const {
  std::lock_guard lock(mutex_);
  return std::any_of(entries_.begin(), entries_.end(), [&](const auto& item) {
    return item.second.ticket == ticket && !item.second.outcome;
  });
}

void RevocationRegistry::Refuse(std::uint64_t ticket, RevocationStatus status) {
  std::lock_guard lock(mutex_);
  for (auto& [key, entry] : entries_) {
    if (entry.ticket == ticket && !entry.issued && !entry.outcome) {
      entry.outcome = status;
      return;
    }
  }
}

void RevocationRegistry::Invoke(std::uint64_t ticket, std::uint64_t now_ms,
                                const std::function<bool()>& request) {
  {
    std::lock_guard lock(mutex_);
    const auto found = std::find_if(entries_.begin(), entries_.end(), [&](const auto& item) {
      return item.second.ticket == ticket;
    });
    if (found == entries_.end() || found->second.outcome || found->second.issued) return;
    if (now_ms >= found->second.deadline) {
      found->second.outcome = RevocationStatus::kTimeout;
      return;
    }
    found->second.issued = true;
  }
  try {
    // ArchiveAccountManager can return false after scheduling the request.
    // Neither Boolean value proves a refusal or a completed revocation.
    (void)request();
    return;
  } catch (...) {}
  std::lock_guard lock(mutex_);
  for (auto& [key, entry] : entries_) {
    if (entry.ticket == ticket && !entry.outcome) {
      entry.outcome = RevocationStatus::kUnavailable;
      return;
    }
  }
}

void RevocationRegistry::Ended(const std::string& account_id,
                                const std::string& device_id, int status,
                                std::uint64_t now_ms) {
  std::lock_guard lock(mutex_);
  const auto found = entries_.find({account_id, device_id});
  if (found == entries_.end() || !found->second.issued || found->second.terminal) return;
  auto& entry = found->second;
  entry.terminal = true;
  if (!entry.outcome) {
    entry.outcome = now_ms >= entry.deadline ? RevocationStatus::kTimeout :
        status == 0 ? RevocationStatus::kRevoked :
        status == 1 ? RevocationStatus::kCredentials :
        status == 2 ? RevocationStatus::kNetwork : RevocationStatus::kUnavailable;
  }
}

std::vector<RevocationRegistry::Completion> RevocationRegistry::TakeReady(std::uint64_t now_ms) {
  std::lock_guard lock(mutex_);
  std::vector<Completion> ready;
  ready.reserve(entries_.size());
  for (auto it = entries_.begin(); it != entries_.end();) {
    auto& entry = it->second;
    if (!entry.outcome && now_ms >= entry.deadline) entry.outcome = RevocationStatus::kTimeout;
    if (entry.outcome && !entry.delivered) {
      RevocationResult result{it->first.first, it->first.second, *entry.outcome};
      ready.push_back({std::move(result), std::move(entry.reply)});
      entry.delivered = true;
    }
    if (entry.delivered && (!entry.issued || entry.terminal)) it = entries_.erase(it);
    else ++it;
  }
  return ready;
}

void RevocationRegistry::Close() {
  std::lock_guard lock(mutex_);
  closed_ = true;
  for (auto& [key, entry] : entries_) {
    if (!entry.outcome) entry.outcome = RevocationStatus::kUnavailable;
  }
}

}  // namespace sybl::known_device
