#include "file_thumbnail_wire.h"

#include "timeline_wire.h"

#include <charconv>
#include <utility>

namespace sybl::file_thumbnail_wire {
namespace {

constexpr std::string_view kPrefix = "SYBLTHUMB1";
constexpr std::string_view kDeclinedPrefix = "SYBLDECLINED1";

bool IsFresh(std::int64_t timestamp_ms, std::int64_t now_ms) {
  if (timestamp_ms < 0 || now_ms < 0) return false;
  return timestamp_ms >= now_ms
             ? timestamp_ms - now_ms <= kMaxAgeMs
             : now_ms - timestamp_ms <= kMaxAgeMs;
}

bool IsValidId(std::string_view value) {
  if (value.empty() || value.size() > kMaxIdUtf8Bytes ||
      !timeline::MeasureUtf8(value, kMaxIdUtf8Bytes)) {
    return false;
  }
  for (const unsigned char byte : value) {
    if (byte < 0x20 || byte == 0x7f || byte == '"' || byte == '\\')
      return false;
  }
  return true;
}

bool IsBase64Char(char value) {
  return (value >= 'A' && value <= 'Z') ||
         (value >= 'a' && value <= 'z') ||
         (value >= '0' && value <= '9') || value == '+' || value == '/';
}

bool IsValidBase64(std::string_view value) {
  if (value.empty() || value.size() > kMaxBase64Chars ||
      value.size() % 4 != 0) {
    return false;
  }
  const std::size_t padding =
      value.back() == '='
          ? (value.size() > 1 && value[value.size() - 2] == '=' ? 2 : 1)
          : 0;
  for (std::size_t index = 0; index < value.size() - padding; ++index) {
    if (!IsBase64Char(value[index])) return false;
  }
  for (std::size_t index = value.size() - padding; index < value.size();
       ++index) {
    if (value[index] != '=') return false;
  }
  return value.size() / 4 * 3 - padding <= kMaxPngBytes;
}

bool IsValid(const Packet& packet, std::int64_t now_ms) {
  return IsValidId(packet.conversation_id) && IsValidId(packet.file_id) &&
         IsFresh(packet.timestamp_ms, now_ms) &&
         IsValidBase64(packet.png_base64);
}

}  // namespace

std::optional<std::string> Encode(const Packet& packet,
                                  std::int64_t now_ms) {
  if (!IsValid(packet, now_ms)) return std::nullopt;
  std::string body;
  body.reserve(kPrefix.size() + packet.conversation_id.size() +
               packet.file_id.size() + packet.png_base64.size() + 32);
  body.append(kPrefix)
      .append("\n")
      .append(packet.conversation_id)
      .append("\n")
      .append(packet.file_id)
      .append("\n")
      .append(std::to_string(packet.timestamp_ms))
      .append("\n")
      .append(packet.png_base64);
  if (body.size() > kMaxBodyBytes) return std::nullopt;
  return body;
}

std::optional<Packet> Decode(std::string_view body, std::int64_t now_ms) {
  if (body.size() > kMaxBodyBytes) return std::nullopt;

  std::string_view parts[5];
  for (std::size_t index = 0, start = 0; index < 4; ++index) {
    const auto end = body.find('\n', start);
    if (end == std::string_view::npos) return std::nullopt;
    parts[index] = body.substr(start, end - start);
    start = end + 1;
    if (index == 3) parts[4] = body.substr(start);
  }
  if (parts[0] != kPrefix || parts[4].find('\n') != std::string_view::npos)
    return std::nullopt;

  std::int64_t timestamp_ms = 0;
  const auto parsed = std::from_chars(parts[3].data(),
                                      parts[3].data() + parts[3].size(),
                                      timestamp_ms);
  if (parts[3].empty() || parsed.ec != std::errc{} ||
      parsed.ptr != parts[3].data() + parts[3].size()) {
    return std::nullopt;
  }

  if (!IsValidId(parts[1]) || !IsValidId(parts[2])) return std::nullopt;
  Packet packet{std::string(parts[1]), std::string(parts[2]), timestamp_ms,
                std::string(parts[4])};
  return IsValid(packet, now_ms)
             ? std::optional<Packet>(std::move(packet))
             : std::nullopt;
}

std::optional<std::string> EncodeDeclined(const DecisionPacket& packet) {
  if (!IsValidId(packet.conversation_id) || !IsValidId(packet.file_id)) {
    return std::nullopt;
  }
  return std::string(kDeclinedPrefix) + "\n" + packet.conversation_id +
         "\n" + packet.file_id;
}

std::optional<DecisionPacket> DecodeDeclined(std::string_view body) {
  if (body.size() > kMaxDeclinedBodyBytes) return std::nullopt;
  const auto first = body.find('\n');
  const auto second = first == std::string_view::npos
                          ? std::string_view::npos
                          : body.find('\n', first + 1);
  if (first == std::string_view::npos || second == std::string_view::npos ||
      body.find('\n', second + 1) != std::string_view::npos ||
      body.substr(0, first) != kDeclinedPrefix) {
    return std::nullopt;
  }
  const auto conversation = body.substr(first + 1, second - first - 1);
  const auto file = body.substr(second + 1);
  if (!IsValidId(conversation) || !IsValidId(file)) return std::nullopt;
  return DecisionPacket{std::string(conversation), std::string(file)};
}

}  // namespace sybl::file_thumbnail_wire
