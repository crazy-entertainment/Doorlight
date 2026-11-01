#include "presence_wire.h"

#include "identity_color_wire.h"
#include "presence_metadata.h"
#include "timeline_wire.h"

#include <json/json.h>

#include <algorithm>
#include <memory>
#include <set>

namespace sybl::presence_wire {
namespace {

bool Integer(const Json::Value& value) {
  return value.type() == Json::intValue || value.type() == Json::uintValue;
}

std::optional<std::string> Activity(std::string value) {
  while (!value.empty() && value.front() == ' ') value.erase(value.begin());
  while (!value.empty() && value.back() == ' ') value.pop_back();
  const auto measured = timeline::MeasureUtf8(
      value, presence_metadata::kMaxActivityUtf8Bytes);
  if (!measured) return std::nullopt;
  if (std::any_of(value.begin(), value.end(), [](unsigned char ch) {
        return ch < 0x20 || ch == 0x7f || ch == '"' || ch == '\\';
      })) {
    return std::nullopt;
  }
  return value;
}

bool ExactKeys(const Json::Value& value, int version) {
  std::set<std::string> actual;
  for (const auto& key : value.getMemberNames()) actual.insert(key);
  const std::set<std::string> legacy{"t", "fg", "ts", "platform", "activity"};
  auto expected = legacy;
  if (version >= 1) expected.insert("v");
  if (version >= 2) expected.insert("color");
  if (version == kVersion) expected.insert("wake");
  return actual == expected;
}

bool WakeHandle(std::string_view value) {
  return value.size() == 43 && std::all_of(value.begin(), value.end(), [](char ch) {
    return (ch >= 'A' && ch <= 'Z') || (ch >= 'a' && ch <= 'z') ||
           (ch >= '0' && ch <= '9') || ch == '_' || ch == '-';
  });
}

}  // namespace

std::string Encode(std::string_view type, bool foreground,
                   std::int64_t timestamp_ms, std::string_view activity,
                   std::string_view color, std::string_view wake) {
  if ((type != "ping" && type != "pong" && type != "wake") ||
      timestamp_ms <= 0 ||
      ((!wake.empty() || type == "wake") && !WakeHandle(wake))) return {};
  const auto safe_activity = Activity(std::string(activity));
  if (!safe_activity || !identity_color_wire::Index(color)) return {};
  Json::Value root(Json::objectValue);
  root["v"] = kVersion;
  root["t"] = std::string(type);
  root["fg"] = foreground ? 1 : 0;
  root["ts"] = Json::Int64(timestamp_ms);
  root["platform"] = "windows";
  root["activity"] = *safe_activity;
  root["color"] = std::string(color);
  root["wake"] = std::string(wake);
  Json::StreamWriterBuilder writer;
  writer["indentation"] = "";
  writer["emitUTF8"] = true;
  return Json::writeString(writer, root);
}

std::optional<Packet> Decode(std::string_view body, std::int64_t now_ms) {
  if (body == "1") return Packet{0, "ping", -1, 0, "", "", "", ""};
  if (body.empty() || body.size() > kMaxBodyBytes || now_ms <= 0)
    return std::nullopt;

  Json::CharReaderBuilder builder;
  Json::CharReaderBuilder::strictMode(&builder.settings_);
  builder["collectComments"] = false;
  Json::Value root;
  std::string errors;
  const auto reader = std::unique_ptr<Json::CharReader>(builder.newCharReader());
  if (!reader || !reader->parse(body.data(), body.data() + body.size(), &root, &errors) ||
      !root.isObject()) {
    return std::nullopt;
  }

  const int version = root.isMember("v") && Integer(root["v"]) && root["v"].isInt()
      ? root["v"].asInt()
      : (root.isMember("v") ? -1 : 0);
  if (version < 0 || version > kVersion || !ExactKeys(root, version))
    return std::nullopt;
  if (!root["t"].isString() || !Integer(root["fg"]) || !root["fg"].isInt() ||
      !Integer(root["ts"]) || !root["ts"].isInt64() || !root["platform"].isString() ||
      !root["activity"].isString()) {
    return std::nullopt;
  }
  Packet packet;
  packet.version = version;
  packet.type = root["t"].asString();
  packet.foreground = root["fg"].asInt();
  packet.timestamp_ms = root["ts"].asInt64();
  packet.platform = root["platform"].asString();
  const auto activity = Activity(root["activity"].asString());
  if ((packet.type != "ping" && packet.type != "pong" &&
       (version != kVersion || packet.type != "wake")) ||
      (packet.foreground != 0 && packet.foreground != 1) ||
      packet.timestamp_ms <= 0 ||
      (packet.timestamp_ms < now_ms &&
       now_ms - packet.timestamp_ms > kMaxClockDeltaMs) ||
      (packet.timestamp_ms > now_ms &&
       packet.timestamp_ms - now_ms > kMaxClockDeltaMs) ||
      (packet.platform != "android" && packet.platform != "windows") ||
      !activity ||
      (version >= 2 &&
       (!root["color"].isString() ||
        !identity_color_wire::Index(root["color"].asString()))) ||
      (version == kVersion &&
       (!root["wake"].isString() ||
        ((!root["wake"].asString().empty() || packet.type == "wake") &&
         !WakeHandle(root["wake"].asString()))))) {
    return std::nullopt;
  }
  packet.activity = *activity;
  if (version >= 2) packet.color = root["color"].asString();
  if (version == kVersion) packet.wake = root["wake"].asString();
  return packet;
}

}  // namespace sybl::presence_wire
