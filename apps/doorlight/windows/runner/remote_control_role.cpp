#include "remote_control_role.h"

namespace sybl::remote {

bool RemoteControlRoleRegistry::TryClaim(const std::string& call_id,
                                         LocalControlRole role) {
  if (call_id.empty() || role == LocalControlRole::kNone) return false;
  std::lock_guard<std::mutex> lock(mutex_);
  const auto found = roles_.find(call_id);
  if (found != roles_.end()) return found->second == role;
  roles_[call_id] = role;
  return true;
}

LocalControlRole RemoteControlRoleRegistry::RoleFor(
    const std::string& call_id) const {
  std::lock_guard<std::mutex> lock(mutex_);
  const auto found = roles_.find(call_id);
  return found == roles_.end() ? LocalControlRole::kNone : found->second;
}

bool RemoteControlRoleRegistry::Release(const std::string& call_id,
                                        LocalControlRole role) {
  std::lock_guard<std::mutex> lock(mutex_);
  const auto found = roles_.find(call_id);
  if (found == roles_.end() || found->second != role) return false;
  roles_.erase(found);
  return true;
}

std::vector<std::pair<std::string, LocalControlRole>>
RemoteControlRoleRegistry::Snapshot() const {
  std::lock_guard<std::mutex> lock(mutex_);
  return {roles_.begin(), roles_.end()};
}

}  // namespace sybl::remote
