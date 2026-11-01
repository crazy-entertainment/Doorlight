#pragma once

#include <optional>
#include <set>
#include <string>
#include <vector>

namespace sybl::group {

inline constexpr std::size_t kMaxTitleUtf8Bytes = 128;
inline constexpr std::size_t kMaxLayoutUtf8Bytes = 8192;
inline constexpr std::size_t kMaxMembers = 64;

std::optional<std::string> NormalizeTitle(const std::string& value);
std::optional<std::string> NormalizeLayout(const std::string& value);

std::optional<std::vector<std::string>> NewMemberIds(
    const std::vector<std::string>& requested,
    const std::string& self_id,
    const std::set<std::string>& trusted_ids,
    const std::set<std::string>& existing_ids = {});

}  // namespace sybl::group
