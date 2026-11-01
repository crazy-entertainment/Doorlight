#pragma once

#include <map>
#include <mutex>
#include <string>
#include <vector>

namespace sybl::remote {

enum class LocalControlRole {
  kNone,
  kController,
  kControllee,
};

class RemoteControlRoleRegistry {
 public:
  bool TryClaim(const std::string& call_id, LocalControlRole role);
  LocalControlRole RoleFor(const std::string& call_id) const;
  bool Release(const std::string& call_id, LocalControlRole role);
  std::vector<std::pair<std::string, LocalControlRole>> Snapshot() const;

 private:
  mutable std::mutex mutex_;
  std::map<std::string, LocalControlRole> roles_;
};

}  // namespace sybl::remote
