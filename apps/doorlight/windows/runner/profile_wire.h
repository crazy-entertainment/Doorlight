#pragma once

#include "timeline_wire.h"

#include <cstddef>
#include <optional>
#include <string>
#include <string_view>
#include <utility>

namespace sybl::profile_wire {

inline constexpr std::size_t kMaxDisplayNameUtf8Bytes = 256;
inline constexpr std::size_t kMaxAvatarDecodedBytes = 256 * 1024;
inline constexpr std::size_t kMaxAvatarBase64Bytes = 350 * 1024;
inline constexpr std::size_t kMaxVCardBytes = kMaxAvatarBase64Bytes + 4096;

struct Profile {
  std::string display_name;
  std::string avatar_base64;
};

inline std::string_view StripVCardLineEnding(std::string_view value) {
  if (!value.empty() && value.back() == '\r') value.remove_suffix(1);
  return value;
}

// Validate the platform-channel string strictly and reject the entire value at
// the byte boundary. Never truncating means a Unicode grapheme cluster cannot
// be split. An engaged empty string is a valid request to clear the name.
inline std::optional<std::string> DecodeDisplayName(std::string_view value) {
  const auto measure =
      timeline::MeasureUtf8(value, kMaxDisplayNameUtf8Bytes);
  if (!measure || measure->utf8_bytes > kMaxDisplayNameUtf8Bytes)
    return std::nullopt;
  return std::string(value);
}

inline std::optional<std::string> DecodeAvatar(std::string_view value) {
  if (value.size() > kMaxAvatarBase64Bytes || value.size() % 4 != 0)
    return std::nullopt;
  bool padding = false;
  std::size_t padding_count = 0;
  for (const unsigned char c : value) {
    if (c == '=') {
      padding = true;
      if (++padding_count > 2) return std::nullopt;
      continue;
    }
    if (padding ||
        !((c >= 'A' && c <= 'Z') || (c >= 'a' && c <= 'z') ||
          (c >= '0' && c <= '9') || c == '+' || c == '/')) {
      return std::nullopt;
    }
  }
  if (value.empty()) return std::string{};
  const auto decoded_bytes =
      (value.size() / 4) * 3 - padding_count;
  if (decoded_bytes > kMaxAvatarDecodedBytes) return std::nullopt;
  return std::string(value);
}

inline std::optional<Profile> DecodeVCard(std::string_view content) {
  if (content.size() > kMaxVCardBytes ||
      !timeline::MeasureUtf8(content, kMaxVCardBytes)) {
    return std::nullopt;
  }

  std::optional<std::string> display_name;
  std::string avatar_base64;
  for (std::size_t start = 0; start <= content.size();) {
    const auto end = content.find('\n', start);
    auto line = StripVCardLineEnding(content.substr(
        start, end == std::string_view::npos ? content.size() - start
                                             : end - start));
    const auto separator = line.find(':');
    if (separator != std::string_view::npos) {
      const auto key = line.substr(0, separator);
      const auto value = line.substr(separator + 1);
      if (!display_name && key == "FN") {
        display_name = DecodeDisplayName(value);
        if (!display_name) return std::nullopt;
      } else if (avatar_base64.empty() &&
                 (key == "PHOTO" ||
                  (key.size() >= 6 && key.substr(0, 6) == "PHOTO;"))) {
        avatar_base64 = DecodeAvatar(value).value_or(std::string{});
      }
    }
    if (end == std::string_view::npos) break;
    start = end + 1;
  }
  if (!display_name) return std::nullopt;
  return Profile{std::move(*display_name), std::move(avatar_base64)};
}

}  // namespace sybl::profile_wire
