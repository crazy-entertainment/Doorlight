#include "remote_control_protocol.h"
#include "identity_color_wire.h"

#include <json/json.h>

#include <algorithm>
#include <cmath>
#include <cstddef>
#include <limits>
#include <memory>
#include <set>
#include <string_view>
#include <type_traits>

namespace sybl::remote {
namespace {

constexpr std::size_t kMaxTokenBytes = 128;
constexpr std::size_t kMinTokenBytes = 32;
constexpr std::size_t kMaxClipboardIdBytes = 64;
constexpr std::size_t kMinClipboardIdBytes = 16;
constexpr std::size_t kMaxReasonBytes = 16;
constexpr std::int32_t kMaxWheelMagnitude = 12000;

bool HasCommentOutsideString(std::string_view packet) {
  bool in_string = false;
  for (std::size_t i = 0; i < packet.size(); ++i) {
    const char current = packet[i];
    if (in_string) {
      if (current == '\\' && i + 1 < packet.size()) {
        ++i;
      } else if (current == '"') {
        in_string = false;
      }
    } else if (current == '"') {
      in_string = true;
    } else if (current == '/' && i + 1 < packet.size() &&
               (packet[i + 1] == '/' || packet[i + 1] == '*')) {
      return true;
    }
  }
  return false;
}

bool IsLowerHex(std::string_view value) {
  return std::all_of(value.begin(), value.end(), [](char c) {
    return (c >= '0' && c <= '9') || (c >= 'a' && c <= 'f');
  });
}

bool ValidToken(const std::string& value) {
  return value.size() >= kMinTokenBytes && value.size() <= kMaxTokenBytes &&
      value.size() % 2 == 0 && IsLowerHex(value);
}

bool ValidClipboardId(const std::string& value) {
  return value.size() >= kMinClipboardIdBytes && value.size() <= kMaxClipboardIdBytes &&
      IsLowerHex(value);
}

bool ValidSha256(const std::string& value) {
  return value.size() == 64 && IsLowerHex(value);
}

bool ValidUtf8(std::string_view value, std::size_t max_bytes) {
  if (value.empty() || value.size() > max_bytes) return false;
  std::size_t i = 0;
  while (i < value.size()) {
    const auto c = static_cast<unsigned char>(value[i]);
    if (c <= 0x7f) {
      if (c == 0 || (c < 0x20 && c != '\n' && c != '\r' && c != '\t')) return false;
      ++i;
      continue;
    }
    std::size_t continuation = 0;
    std::uint32_t codepoint = 0;
    if ((c & 0xe0) == 0xc0) {
      continuation = 1;
      codepoint = c & 0x1f;
      if (codepoint < 2) return false;  // overlong
    } else if ((c & 0xf0) == 0xe0) {
      continuation = 2;
      codepoint = c & 0x0f;
    } else if ((c & 0xf8) == 0xf0) {
      continuation = 3;
      codepoint = c & 0x07;
    } else {
      return false;
    }
    if (i + continuation >= value.size()) return false;
    for (std::size_t j = 1; j <= continuation; ++j) {
      const auto next = static_cast<unsigned char>(value[i + j]);
      if ((next & 0xc0) != 0x80) return false;
      codepoint = (codepoint << 6) | (next & 0x3f);
    }
    if ((continuation == 2 && codepoint < 0x800) ||
        (continuation == 3 && codepoint < 0x10000) ||
        codepoint > 0x10ffff || (codepoint >= 0xd800 && codepoint <= 0xdfff)) {
      return false;
    }
    i += continuation + 1;
  }
  return true;
}

bool ExactFields(const Json::Value& object, std::initializer_list<const char*> expected) {
  if (!object.isObject() || object.size() != expected.size()) return false;
  std::set<std::string> actual;
  for (const auto& name : object.getMemberNames()) actual.insert(name);
  for (const auto* name : expected) {
    if (actual.erase(name) != 1) return false;
  }
  return actual.empty();
}

bool ReadPositiveUInt64(const Json::Value& value, std::uint64_t& out) {
  if (!value.isUInt64()) return false;
  out = value.asUInt64();
  return out > 0;
}

std::optional<Capability> ParseCapability(const std::string& value) {
  if (value == "mouse") return Capability::kMouse;
  if (value == "keyboard") return Capability::kKeyboard;
  if (value == "text") return Capability::kText;
  if (value == "clipboard") return Capability::kClipboard;
  if (value == "back") return Capability::kBack;
  if (value == "home") return Capability::kHome;
  if (value == "recents") return Capability::kRecents;
  return std::nullopt;
}

const char* CapabilityName(Capability capability) {
  switch (capability) {
    case Capability::kMouse:
      return "mouse";
    case Capability::kKeyboard:
      return "keyboard";
    case Capability::kText:
      return "text";
    case Capability::kClipboard:
      return "clipboard";
    case Capability::kBack:
      return "back";
    case Capability::kHome:
      return "home";
    case Capability::kRecents:
      return "recents";
  }
  return "";
}

bool ParseCapabilities(const Json::Value& value, Capabilities& out) {
  if (!value.isArray() || value.empty() || value.size() > kMaxCapabilities) return false;
  out = 0;
  for (const auto& entry : value) {
    if (!entry.isString()) return false;
    const auto parsed = ParseCapability(entry.asString());
    if (!parsed) return false;
    const auto bit = CapabilityBit(*parsed);
    if ((out & bit) != 0) return false;
    out = static_cast<Capabilities>(out | bit);
  }
  return out != 0;
}

Json::Value EncodeCapabilities(Capabilities capabilities) {
  Json::Value value(Json::arrayValue);
  for (const auto capability : {Capability::kMouse, Capability::kKeyboard,
                                Capability::kText, Capability::kClipboard,
                                Capability::kBack, Capability::kHome,
                                Capability::kRecents}) {
    if (HasCapability(capabilities, capability)) value.append(CapabilityName(capability));
  }
  return value;
}

std::optional<MouseButton> ParseButton(const std::string& value) {
  if (value == "left") return MouseButton::kLeft;
  if (value == "right") return MouseButton::kRight;
  if (value == "middle") return MouseButton::kMiddle;
  if (value == "x1") return MouseButton::kX1;
  if (value == "x2") return MouseButton::kX2;
  return std::nullopt;
}

const char* ButtonName(MouseButton button) {
  switch (button) {
    case MouseButton::kLeft:
      return "left";
    case MouseButton::kRight:
      return "right";
    case MouseButton::kMiddle:
      return "middle";
    case MouseButton::kX1:
      return "x1";
    case MouseButton::kX2:
      return "x2";
  }
  return "";
}

std::optional<DenyReason> ParseDenyReason(const std::string& value) {
  if (value == "user") return DenyReason::kUser;
  if (value == "timeout") return DenyReason::kTimeout;
  if (value == "unsupported") return DenyReason::kUnsupported;
  if (value == "busy") return DenyReason::kBusy;
  return std::nullopt;
}

const char* DenyReasonName(DenyReason reason) {
  switch (reason) {
    case DenyReason::kUser:
      return "user";
    case DenyReason::kTimeout:
      return "timeout";
    case DenyReason::kUnsupported:
      return "unsupported";
    case DenyReason::kBusy:
      return "busy";
  }
  return "";
}

bool DirectionAllowed(std::string_view type, WireDirection direction) {
  if (type == "clip-offer" || type == "clip-data" || type == "clip-accept" ||
      type == "clip-reject" || type == "end") {
    return true;
  }
  if (direction == WireDirection::kControllerToControllee)
    return type == "req" || type == "input";
  return type == "grant" || type == "deny" || type == "revoke";
}

ProtocolError ParseInputEvent(const Json::Value& value, InputEvent& out) {
  if (!value.isArray() || value.empty() || !value[0].isString()) return ProtocolError::kInvalidValue;
  const auto type = value[0].asString();
  if (type == "m") {
    if (value.size() != 3 || !value[1].isNumeric() || !value[2].isNumeric())
      return ProtocolError::kInvalidValue;
    const double x = value[1].asDouble();
    const double y = value[2].asDouble();
    if (!std::isfinite(x) || !std::isfinite(y) || x < 0 || x > 1 || y < 0 || y > 1)
      return ProtocolError::kInvalidValue;
    out = MoveEvent{x, y};
    return ProtocolError::kNone;
  }
  if (type == "d" || type == "u") {
    if (value.size() != 2 || !value[1].isString()) return ProtocolError::kInvalidValue;
    const auto button = ParseButton(value[1].asString());
    if (!button) return ProtocolError::kInvalidValue;
    out = ButtonEvent{*button, type == "d"};
    return ProtocolError::kNone;
  }
  if (type == "w") {
    if (value.size() != 2 || !value[1].isInt()) return ProtocolError::kInvalidValue;
    const auto delta = value[1].asInt();
    if (delta == 0 || delta < -kMaxWheelMagnitude || delta > kMaxWheelMagnitude)
      return ProtocolError::kInvalidValue;
    out = WheelEvent{delta};
    return ProtocolError::kNone;
  }
  if (type == "k") {
    if (value.size() != 3 || !value[1].isUInt() || !value[2].isBool())
      return ProtocolError::kInvalidValue;
    const auto key = value[1].asUInt();
    if (key == 0 || key > 0xff) return ProtocolError::kInvalidValue;
    out = KeyEvent{static_cast<std::uint16_t>(key), value[2].asBool()};
    return ProtocolError::kNone;
  }
  if (type == "t") {
    if (value.size() != 2 || !value[1].isString()) return ProtocolError::kInvalidValue;
    const auto text = value[1].asString();
    if (!ValidUtf8(text, kMaxTextEventBytes)) return ProtocolError::kInvalidValue;
    out = TextEvent{text};
    return ProtocolError::kNone;
  }
  if (type == "a") {
    if (value.size() != 2 || !value[1].isString())
      return ProtocolError::kInvalidValue;
    const auto action = value[1].asString();
    if (action == "back")
      out = ActionEvent{GlobalAction::kBack};
    else if (action == "home")
      out = ActionEvent{GlobalAction::kHome};
    else if (action == "recents")
      out = ActionEvent{GlobalAction::kRecents};
    else
      return ProtocolError::kInvalidValue;
    return ProtocolError::kNone;
  }
  return ProtocolError::kInvalidValue;
}

Json::Value EncodeInputEvent(const InputEvent& event) {
  return std::visit(
      [](const auto& item) {
        using T = std::decay_t<decltype(item)>;
        Json::Value value(Json::arrayValue);
        if constexpr (std::is_same_v<T, MoveEvent>) {
          value.append("m");
          value.append(item.x);
          value.append(item.y);
        } else if constexpr (std::is_same_v<T, ButtonEvent>) {
          value.append(item.down ? "d" : "u");
          value.append(ButtonName(item.button));
        } else if constexpr (std::is_same_v<T, WheelEvent>) {
          value.append("w");
          value.append(item.delta);
        } else if constexpr (std::is_same_v<T, KeyEvent>) {
          value.append("k");
          value.append(item.virtual_key);
          value.append(item.down);
        } else if constexpr (std::is_same_v<T, TextEvent>) {
          value.append("t");
          value.append(item.utf8);
        } else {
          value.append("a");
          switch (item.action) {
            case GlobalAction::kBack:
              value.append("back");
              break;
            case GlobalAction::kHome:
              value.append("home");
              break;
            case GlobalAction::kRecents:
              value.append("recents");
              break;
          }
        }
        return value;
      },
      event);
}

Json::Value EncodeMessage(const Message& message) {
  Json::Value root(Json::objectValue);
  root["v"] = kProtocolVersion;
  std::visit(
      [&root](const auto& item) {
        using T = std::decay_t<decltype(item)>;
        if constexpr (std::is_same_v<T, RequestMessage>) {
          root["t"] = "req";
          root["caps"] = EncodeCapabilities(item.capabilities);
          root["sourceRevision"] = Json::UInt64(item.source_revision);
          root["color"] = item.identity_color;
        } else if constexpr (std::is_same_v<T, GrantMessage>) {
          root["t"] = "grant";
          root["token"] = item.token;
          root["epoch"] = Json::UInt64(item.epoch);
          root["sourceRevision"] = Json::UInt64(item.source_revision);
          root["caps"] = EncodeCapabilities(item.capabilities);
        } else if constexpr (std::is_same_v<T, DenyMessage>) {
          root["t"] = "deny";
          root["reason"] = DenyReasonName(item.reason);
        } else if constexpr (std::is_same_v<T, RevokeMessage>) {
          root["t"] = "revoke";
        } else if constexpr (std::is_same_v<T, InputMessage>) {
          root["t"] = "input";
          root["token"] = item.token;
          root["epoch"] = Json::UInt64(item.epoch);
          root["seq"] = Json::UInt64(item.sequence);
          root["sourceRevision"] = Json::UInt64(item.source_revision);
          Json::Value events(Json::arrayValue);
          for (const auto& event : item.events) events.append(EncodeInputEvent(event));
          root["ev"] = std::move(events);
        } else if constexpr (std::is_same_v<T, ClipboardOfferMessage>) {
          root["t"] = "clip-offer";
          root["id"] = item.id;
          root["sha256"] = item.sha256;
          root["size"] = item.size;
        } else if constexpr (std::is_same_v<T, ClipboardDataMessage>) {
          root["t"] = "clip-data";
          root["id"] = item.id;
          root["sha256"] = item.sha256;
          root["text"] = item.utf8;
        } else if constexpr (std::is_same_v<T, ClipboardAcceptMessage>) {
          root["t"] = "clip-accept";
          root["id"] = item.id;
        } else if constexpr (std::is_same_v<T, ClipboardRejectMessage>) {
          root["t"] = "clip-reject";
          root["id"] = item.id;
        } else {
          root["t"] = "end";
        }
      },
      message);
  return root;
}

}  // namespace


ParseResult ParsePacket(const std::string& packet, WireDirection direction) {
  if (packet.empty()) return {ProtocolError::kPacketEmpty, std::nullopt};
  if (packet.size() > kMaxPacketBytes) return {ProtocolError::kPacketTooLarge, std::nullopt};
  // The pinned JsonCpp reader can skip comments with allowComments disabled.
  if (HasCommentOutsideString(packet))
    return {ProtocolError::kMalformedJson, std::nullopt};

  Json::CharReaderBuilder builder;
  Json::CharReaderBuilder::strictMode(&builder.settings_);
  builder["allowComments"] = false;
  builder["collectComments"] = false;
  builder["failIfExtra"] = true;
  builder["rejectDupKeys"] = true;
  builder["stackLimit"] = kMaxJsonDepth;
  Json::Value root;
  std::string errors;
  const auto reader = std::unique_ptr<Json::CharReader>(builder.newCharReader());
  if (!reader) return {ProtocolError::kMalformedJson, std::nullopt};
  // stackLimit is the one hardening knob jsoncpp enforces by THROWING rather
  // than returning false: past the depth it calls throwRuntimeError, and
  // neither OurReader::parse nor OurCharReader::parse catches it. Without this
  // guard a ~41-byte deeply nested packet from an authenticated peer escapes
  // the error taxonomy entirely and unwinds into whatever happens to catch it
  // two modules away, so "unknown or malformed input fails inert" would be
  // false as written. Depth beyond about three is meaningless for this
  // protocol (object -> "ev" array -> event array), so anything that trips the
  // limit is malformed by definition.
  try {
    if (!reader->parse(packet.data(), packet.data() + packet.size(), &root,
                       &errors)) {
      return {ProtocolError::kMalformedJson, std::nullopt};
    }
  } catch (...) {
    return {ProtocolError::kMalformedJson, std::nullopt};
  }
  if (!root.isObject()) return {ProtocolError::kRootNotObject, std::nullopt};
  if (!root.isMember("v") || !root["v"].isUInt() ||
      root["v"].asUInt() != kProtocolVersion) {
    return {ProtocolError::kWrongVersion, std::nullopt};
  }
  if (!root.isMember("t") || !root["t"].isString())
    return {ProtocolError::kUnknownOrMissingField, std::nullopt};
  const auto type = root["t"].asString();
  static const std::set<std::string> kKnownTypes{
      "req", "grant", "deny", "revoke", "input", "clip-offer",
      "clip-data", "clip-accept", "clip-reject", "end"};
  if (kKnownTypes.find(type) == kKnownTypes.end())
    return {ProtocolError::kUnknownType, std::nullopt};
  if (!DirectionAllowed(type, direction))
    return {ProtocolError::kWrongDirection, std::nullopt};

  if (type == "req") {
    if (!ExactFields(root, {"v", "t", "caps", "sourceRevision", "color"}))
      return {ProtocolError::kUnknownOrMissingField, std::nullopt};
    RequestMessage message;
    if (!ParseCapabilities(root["caps"], message.capabilities) ||
        !ReadPositiveUInt64(root["sourceRevision"], message.source_revision) ||
        !root["color"].isString() ||
        !identity_color_wire::Index(root["color"].asString()))
      return {ProtocolError::kInvalidValue, std::nullopt};
    message.identity_color = root["color"].asString();
    return {ProtocolError::kNone, Message{std::move(message)}};
  }
  if (type == "grant") {
    if (!ExactFields(root, {"v", "t", "token", "epoch", "sourceRevision", "caps"}))
      return {ProtocolError::kUnknownOrMissingField, std::nullopt};
    GrantMessage message;
    if (!root["token"].isString() || !ValidToken(root["token"].asString()) ||
        !ReadPositiveUInt64(root["epoch"], message.epoch) ||
        !ReadPositiveUInt64(root["sourceRevision"], message.source_revision) ||
        !ParseCapabilities(root["caps"], message.capabilities))
      return {ProtocolError::kInvalidValue, std::nullopt};
    message.token = root["token"].asString();
    return {ProtocolError::kNone, Message{std::move(message)}};
  }
  if (type == "deny") {
    if (!ExactFields(root, {"v", "t", "reason"}) || !root["reason"].isString() ||
        root["reason"].asString().size() > kMaxReasonBytes)
      return {ProtocolError::kUnknownOrMissingField, std::nullopt};
    const auto reason = ParseDenyReason(root["reason"].asString());
    if (!reason) return {ProtocolError::kInvalidValue, std::nullopt};
    return {ProtocolError::kNone, Message{DenyMessage{*reason}}};
  }
  if (type == "revoke") {
    if (!ExactFields(root, {"v", "t"}))
      return {ProtocolError::kUnknownOrMissingField, std::nullopt};
    return {ProtocolError::kNone, Message{RevokeMessage{}}};
  }
  if (type == "input") {
    if (!ExactFields(root, {"v", "t", "token", "epoch", "seq", "sourceRevision", "ev"}))
      return {ProtocolError::kUnknownOrMissingField, std::nullopt};
    InputMessage message;
    if (!root["token"].isString() || !ValidToken(root["token"].asString()) ||
        !ReadPositiveUInt64(root["epoch"], message.epoch) ||
        !ReadPositiveUInt64(root["seq"], message.sequence) ||
        !ReadPositiveUInt64(root["sourceRevision"], message.source_revision) ||
        !root["ev"].isArray() || root["ev"].empty())
      return {ProtocolError::kInvalidValue, std::nullopt};
    if (root["ev"].size() > kMaxInputEvents)
      return {ProtocolError::kTooManyEvents, std::nullopt};
    message.token = root["token"].asString();
    for (const auto& raw : root["ev"]) {
      InputEvent event;
      const auto error = ParseInputEvent(raw, event);
      if (error != ProtocolError::kNone) return {error, std::nullopt};
      message.events.push_back(std::move(event));
    }
    return {ProtocolError::kNone, Message{std::move(message)}};
  }
  if (type == "clip-offer") {
    if (!ExactFields(root, {"v", "t", "id", "sha256", "size"}) ||
        !root["id"].isString() || !root["sha256"].isString() || !root["size"].isUInt())
      return {ProtocolError::kUnknownOrMissingField, std::nullopt};
    ClipboardOfferMessage message{root["id"].asString(), root["sha256"].asString(),
                                  root["size"].asUInt()};
    if (!ValidClipboardId(message.id) || !ValidSha256(message.sha256) ||
        message.size == 0 || message.size > kMaxClipboardBytes)
      return {ProtocolError::kInvalidValue, std::nullopt};
    return {ProtocolError::kNone, Message{std::move(message)}};
  }
  if (type == "clip-data") {
    if (!ExactFields(root, {"v", "t", "id", "sha256", "text"}) ||
        !root["id"].isString() || !root["sha256"].isString() || !root["text"].isString())
      return {ProtocolError::kUnknownOrMissingField, std::nullopt};
    ClipboardDataMessage message{root["id"].asString(), root["sha256"].asString(),
                                 root["text"].asString()};
    if (!ValidClipboardId(message.id) || !ValidSha256(message.sha256) ||
        !ValidUtf8(message.utf8, kMaxClipboardBytes))
      return {ProtocolError::kInvalidValue, std::nullopt};
    return {ProtocolError::kNone, Message{std::move(message)}};
  }
  if (type == "clip-accept" || type == "clip-reject") {
    if (!ExactFields(root, {"v", "t", "id"}) || !root["id"].isString() ||
        !ValidClipboardId(root["id"].asString()))
      return {ProtocolError::kUnknownOrMissingField, std::nullopt};
    if (type == "clip-accept")
      return {ProtocolError::kNone, Message{ClipboardAcceptMessage{root["id"].asString()}}};
    return {ProtocolError::kNone, Message{ClipboardRejectMessage{root["id"].asString()}}};
  }
  if (type == "end") {
    if (!ExactFields(root, {"v", "t"}))
      return {ProtocolError::kUnknownOrMissingField, std::nullopt};
    return {ProtocolError::kNone, Message{EndMessage{}}};
  }
  return {ProtocolError::kUnknownType, std::nullopt};
}

SerializeResult SerializePacket(const Message& message, WireDirection direction) {
  Json::StreamWriterBuilder builder;
  builder["indentation"] = "";
  builder["commentStyle"] = "None";
  builder["enableYAMLCompatibility"] = false;
  builder["dropNullPlaceholders"] = false;
  const auto packet = Json::writeString(builder, EncodeMessage(message));
  if (packet.size() > kMaxPacketBytes) return {ProtocolError::kPacketTooLarge, {}};
  const auto checked = ParsePacket(packet, direction);
  if (!checked) return {checked.error, {}};
  return {ProtocolError::kNone, packet};
}

}  // namespace sybl::remote
