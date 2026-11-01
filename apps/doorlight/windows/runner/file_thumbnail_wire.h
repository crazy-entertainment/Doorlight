#pragma once

#include <cstddef>
#include <cstdint>
#include <optional>
#include <string>
#include <string_view>

namespace sybl::file_thumbnail_wire {

inline constexpr std::size_t kMaxIdUtf8Bytes = 4096;
inline constexpr std::size_t kMaxDeclinedBodyBytes = 13 + 2 + kMaxIdUtf8Bytes * 2;
inline constexpr std::size_t kMaxPngBytes = 24 * 1024;
inline constexpr std::size_t kMaxBase64Chars = 32 * 1024;
inline constexpr std::size_t kMaxBodyBytes =
    kMaxBase64Chars + kMaxIdUtf8Bytes * 2 + 96;
inline constexpr std::int64_t kMaxAgeMs = 60'000;

struct Packet {
  std::string conversation_id;
  std::string file_id;
  std::int64_t timestamp_ms;
  std::string png_base64;
};

struct DecisionPacket {
  std::string conversation_id;
  std::string file_id;
};

std::optional<std::string> Encode(const Packet& packet,
                                  std::int64_t now_ms);
std::optional<Packet> Decode(std::string_view body, std::int64_t now_ms);
std::optional<std::string> EncodeDeclined(const DecisionPacket& packet);
std::optional<DecisionPacket> DecodeDeclined(std::string_view body);

}  // namespace sybl::file_thumbnail_wire
