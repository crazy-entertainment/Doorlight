#pragma once

#include <cstdint>
#include <optional>
#include <string>
#include <string_view>

namespace sybl::presence_wire {

inline constexpr int kVersion = 3;
inline constexpr std::size_t kMaxBodyBytes = 512;
inline constexpr std::int64_t kMaxClockDeltaMs = 60000;

struct Packet {
  int version = 0;
  std::string type;
  int foreground = -1;
  std::int64_t timestamp_ms = 0;
  std::string platform;
  std::string activity;
  std::string color;
  std::string wake;
};

std::string Encode(std::string_view type, bool foreground,
                   std::int64_t timestamp_ms, std::string_view activity,
                   std::string_view color, std::string_view wake = {});
std::optional<Packet> Decode(std::string_view body, std::int64_t now_ms);

}  // namespace sybl::presence_wire
