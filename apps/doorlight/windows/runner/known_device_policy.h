#pragma once

#include <map>
#include <cstdint>
#include <functional>
#include <mutex>
#include <optional>
#include <string>
#include <string_view>
#include <vector>

namespace sybl::known_device {

inline constexpr std::size_t kMaxDevices = 64;
inline constexpr std::size_t kMaxNameUtf8Bytes = 128;

struct Device {
  std::string id;
  std::string name;
  bool current = false;
};

bool IsDeviceId(std::string_view value);
std::string BoundedName(std::string_view value);
std::vector<Device> Project(const std::map<std::string, std::string>& known,
                            std::string_view current_id);
bool CanRevoke(std::string_view requested_id, std::string_view current_id,
               const std::map<std::string, std::string>& known);

enum class RevocationStatus {
  kRevoked, kCredentials, kNetwork, kTimeout, kPending, kRefused,
  kAccountChanged, kUnavailable,
};
const char* RevocationStatusName(RevocationStatus status);

struct RevocationResult {
  std::string account_id;
  std::string device_id;
  RevocationStatus status = RevocationStatus::kUnavailable;
};

// DeviceRevocationEnded has no operation id. An issued request whose result is
// unknown retains its exact account/device slot until that callback is consumed.
// This prevents an older callback from completing a later retry.
class RevocationRegistry {
 public:
  static constexpr std::uint64_t kTimeoutMs = 30'000;
  using Reply = std::function<void(const RevocationResult&)>;
  struct Admission {
    std::uint64_t ticket = 0;
    RevocationStatus status = RevocationStatus::kUnavailable;
  };
  struct Completion {
    RevocationResult result;
    Reply reply;
  };

  void SelectAccount(const std::string& account_id);
  Admission Begin(const std::string& account_id, const std::string& device_id,
                  std::uint64_t now_ms, Reply reply);
  bool Pending(std::uint64_t ticket) const;
  void Refuse(std::uint64_t ticket, RevocationStatus status);
  void Invoke(std::uint64_t ticket, std::uint64_t now_ms,
              const std::function<bool()>& request);
  void Ended(const std::string& account_id, const std::string& device_id,
             int status, std::uint64_t now_ms);
  std::vector<Completion> TakeReady(std::uint64_t now_ms);
  void Close();

 private:
  struct Entry {
    std::uint64_t ticket;
    std::uint64_t deadline;
    Reply reply;
    bool issued = false;
    bool terminal = false;
    bool delivered = false;
    std::optional<RevocationStatus> outcome;
  };
  mutable std::mutex mutex_;
  std::string account_id_;
  std::uint64_t next_ticket_ = 0;
  bool closed_ = false;
  std::map<std::pair<std::string, std::string>, Entry> entries_;
};

}  // namespace sybl::known_device
