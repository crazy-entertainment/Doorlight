#pragma once

#include <algorithm>
#include <map>
#include <optional>
#include <string>

#include "timeline_wire.h"

namespace sybl::rich_timeline {
inline constexpr char kStickerMime[] = "application/x-sybl-sticker+json";

inline bool BoundedBody(const std::string& value) {
  return value.size() <= 1024 && timeline::IsRequiredUtf8(value, 1024);
}

// Inputs are daemon-authenticated commit fields, never sender body claims.
inline std::optional<std::map<std::string, std::string>> Project(
    const std::map<std::string, std::string>& body, bool group) {
  // Folded reaction removals can also arrive through SwarmMessageUpdated.
  if (const auto reaction = body.find("react-to");
      reaction != body.end() && !reaction->second.empty()) return std::nullopt;
  std::map<std::string, std::string> result;
  if (const auto reply = body.find("reply-to"); reply != body.end()) {
    if (!timeline::IsOptionalUtf8(reply->second, timeline::kMaxDaemonIdCodeUnits)) return std::nullopt;
    result.emplace("replyTo", reply->second);
  }
  const auto topic = body.find("sybl-topic-v1");
  if (group && topic != body.end() && !topic->second.empty()) return std::nullopt;
  if (const auto room = body.find("sybl-room-v1"); room != body.end()) {
    const auto& value = room->second;
    const auto alphanumeric = [](char c) {
      return (c >= 'a' && c <= 'z') || (c >= '0' && c <= '9');
    };
    if (!group || value.empty() || value.size() > 32 ||
        !alphanumeric(value.front()) ||
        !std::all_of(value.begin(), value.end(), [&](char c) {
          return alphanumeric(c) || c == '-';
        })) return std::nullopt;
    result.emplace("roomId", value);
  }
  if (const auto op = body.find("sybl-op-v1"); op != body.end()) {
    const auto& value = op->second;
    if (value.size() != 32 || !std::all_of(value.begin(), value.end(), [](char c) {
          return (c >= '0' && c <= '9') || (c >= 'a' && c <= 'f');
        })) return std::nullopt;
    result.emplace("operationId", value);
  }
  if (const auto media = body.find("sybl-media-v1"); media != body.end()) {
    if (!BoundedBody(media->second)) return std::nullopt;
    result.emplace("mediaMetadata", media->second);
  }
  return result;
}
}  // namespace sybl::rich_timeline
