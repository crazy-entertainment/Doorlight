#pragma once

#include <cstdint>
#include <optional>
#include <string>
#include <string_view>
#include <variant>
#include <vector>

namespace sybl::remote {

constexpr std::uint32_t kProtocolVersion = 1;
// Keep this identical to jami_bridge's typed in-call MESSAGE firewall. A
// packet accepted by the protocol serializer must not be rejected by the
// bridge merely because the two layers disagree about what "~6 KB" means.
constexpr std::size_t kMaxPacketBytes = 6000;
constexpr unsigned int kMaxJsonDepth = 20;
constexpr std::size_t kMaxInputEvents = 64;
constexpr std::size_t kMaxTextEventBytes = 256;
constexpr std::size_t kMaxClipboardBytes = 4096;
constexpr std::size_t kMaxCapabilities = 7;

// Exact text work submitted by the Windows adapter: two primitives per UTF-16 unit.
inline std::optional<std::size_t> RemoteTextUtf16Units(std::string_view value) {
  if (value.empty() || value.size() > kMaxTextEventBytes) return std::nullopt;
  std::size_t units = 0;
  for (std::size_t i = 0; i < value.size();) {
    const auto first = static_cast<unsigned char>(value[i++]);
    if (first < 0x80) {
      if (!first || (first < 0x20 && first != '\n' && first != '\r' && first != '\t'))
        return std::nullopt;
      ++units;
      continue;
    }
    const unsigned continuation = first >= 0xc2 && first <= 0xdf ? 1 :
        first >= 0xe0 && first <= 0xef ? 2 : first >= 0xf0 && first <= 0xf4 ? 3 : 0;
    if (!continuation || i + continuation > value.size()) return std::nullopt;
    std::uint32_t point = first & (continuation == 1 ? 0x1f : continuation == 2 ? 0x0f : 0x07);
    for (unsigned j = 0; j < continuation; ++j) {
      const auto next = static_cast<unsigned char>(value[i++]);
      if ((next & 0xc0) != 0x80) return std::nullopt;
      point = (point << 6) | (next & 0x3f);
    }
    if ((continuation == 2 && point < 0x800) ||
        (continuation == 3 && point < 0x10000) || point > 0x10ffff ||
        (point >= 0xd800 && point <= 0xdfff)) return std::nullopt;
    units += point > 0xffff ? 2 : 1;
  }
  return units;
}

enum class WireDirection {
  kControllerToControllee,
  kControlleeToController,
};

enum class Capability : std::uint8_t {
  kMouse = 1,
  kKeyboard = 2,
  kText = 4,
  kClipboard = 8,
  kBack = 16,
  kHome = 32,
  kRecents = 64,
};

using Capabilities = std::uint8_t;

constexpr Capabilities CapabilityBit(Capability capability) {
  return static_cast<Capabilities>(capability);
}

constexpr bool HasCapability(Capabilities capabilities, Capability capability) {
  return (capabilities & CapabilityBit(capability)) != 0;
}

enum class MouseButton {
  kLeft,
  kRight,
  kMiddle,
  kX1,
  kX2,
};

struct MoveEvent {
  double x = 0;
  double y = 0;
};

struct ButtonEvent {
  MouseButton button = MouseButton::kLeft;
  bool down = false;
};

struct WheelEvent {
  std::int32_t delta = 0;
};

struct KeyEvent {
  std::uint16_t virtual_key = 0;
  bool down = false;
};

struct TextEvent {
  std::string utf8;
};

enum class GlobalAction {
  kBack,
  kHome,
  kRecents,
};

struct ActionEvent {
  GlobalAction action = GlobalAction::kBack;
};

using InputEvent = std::variant<MoveEvent, ButtonEvent, WheelEvent, KeyEvent,
                                TextEvent, ActionEvent>;

struct RequestMessage {
  Capabilities capabilities = 0;
  std::uint64_t source_revision = 0;
  std::string identity_color = "amber";
};

struct GrantMessage {
  std::string token;
  std::uint64_t epoch = 0;
  std::uint64_t source_revision = 0;
  Capabilities capabilities = 0;
};

enum class DenyReason {
  kUser,
  kTimeout,
  kUnsupported,
  kBusy,
};

struct DenyMessage {
  DenyReason reason = DenyReason::kUser;
};

struct RevokeMessage {};

struct InputMessage {
  std::string token;
  std::uint64_t epoch = 0;
  std::uint64_t sequence = 0;
  std::uint64_t source_revision = 0;
  std::vector<InputEvent> events;
};

struct ClipboardOfferMessage {
  std::string id;
  std::string sha256;
  std::uint32_t size = 0;
};

struct ClipboardDataMessage {
  std::string id;
  std::string sha256;
  std::string utf8;
};

struct ClipboardAcceptMessage {
  std::string id;
};

struct ClipboardRejectMessage {
  std::string id;
};

struct EndMessage {};

using Message = std::variant<RequestMessage,
                             GrantMessage,
                             DenyMessage,
                             RevokeMessage,
                             InputMessage,
                             ClipboardOfferMessage,
                             ClipboardDataMessage,
                             ClipboardAcceptMessage,
                             ClipboardRejectMessage,
                             EndMessage>;

enum class ProtocolError {
  kNone,
  kPacketEmpty,
  kPacketTooLarge,
  kMalformedJson,
  kRootNotObject,
  kUnknownOrMissingField,
  kWrongVersion,
  kUnknownType,
  kWrongDirection,
  kInvalidValue,
  kTooManyEvents,
  kCapabilityMismatch,
};

struct ParseResult {
  ProtocolError error = ProtocolError::kNone;
  std::optional<Message> message;

  explicit operator bool() const { return error == ProtocolError::kNone && message.has_value(); }
};

struct SerializeResult {
  ProtocolError error = ProtocolError::kNone;
  std::string packet;

  explicit operator bool() const { return error == ProtocolError::kNone; }
};

ParseResult ParsePacket(const std::string& packet, WireDirection direction);
SerializeResult SerializePacket(const Message& message, WireDirection direction);

}  // namespace sybl::remote
