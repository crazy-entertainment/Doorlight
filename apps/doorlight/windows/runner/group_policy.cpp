#include "group_policy.h"

#include "friend_routing.h"
#include "timeline_wire.h"

#include <algorithm>

namespace sybl::group {

std::optional<std::string> NormalizeTitle(const std::string& value) {
  const auto first = value.find_first_not_of(" \t\r\n");
  if (first == std::string::npos) return std::nullopt;
  const auto last = value.find_last_not_of(" \t\r\n");
  auto normalized = value.substr(first, last - first + 1);
  if (normalized.size() > kMaxTitleUtf8Bytes ||
      !sybl::timeline::IsRequiredUtf8(normalized, kMaxTitleUtf8Bytes)) {
    return std::nullopt;
  }
  for (const unsigned char value_byte : normalized) {
    if (value_byte < 0x20 || value_byte == 0x7f) return std::nullopt;
  }
  return normalized;
}

std::optional<std::string> NormalizeLayout(const std::string& value) {
  constexpr auto prefix = "sybl-group-layout:v1:";
  if (value.size() <= std::char_traits<char>::length(prefix) ||
      value.size() > kMaxLayoutUtf8Bytes ||
      value.rfind(prefix, 0) != 0) {
    return std::nullopt;
  }
  for (auto it = value.begin() + std::char_traits<char>::length(prefix);
       it != value.end(); ++it) {
    const unsigned char byte = *it;
    const bool is_ascii_alphanumeric =
        (byte >= 'a' && byte <= 'z') || (byte >= 'A' && byte <= 'Z') ||
        (byte >= '0' && byte <= '9');
    if (!(is_ascii_alphanumeric || byte == '-' || byte == '_')) {
      return std::nullopt;
    }
  }
  return value;
}

std::optional<std::vector<std::string>> NewMemberIds(
    const std::vector<std::string>& requested,
    const std::string& self_id,
    const std::set<std::string>& trusted_ids,
    const std::set<std::string>& existing_ids) {
  const auto self = sybl::routing::BareJamiId(self_id);
  std::set<std::string> unique;
  for (const auto& raw : requested) {
    const auto id = sybl::routing::BareJamiId(raw);
    if (id.empty() || id == self || trusted_ids.find(id) == trusted_ids.end() ||
        existing_ids.find(id) != existing_ids.end() || !unique.insert(id).second) {
      return std::nullopt;
    }
  }
  if (unique.empty() || existing_ids.size() + unique.size() + 1 > kMaxMembers) {
    return std::nullopt;
  }
  return std::vector<std::string>(unique.begin(), unique.end());
}

}  // namespace sybl::group
