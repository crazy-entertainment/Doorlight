#include "hologram_wire.h"
#include <json/json.h>
#include <memory>
#include <set>

namespace sybl::hologram {
namespace {
bool Hex(const Json::Value& value, size_t length) {
  if (!value.isString()) return false;
  const auto text = value.asString();
  if (text.size() != length) return false;
  for (char c : text) if (!((c >= '0' && c <= '9') || (c >= 'a' && c <= 'f'))) return false;
  return true;
}
}
std::optional<Packet> Decode(const std::string& body) {
  if (body.empty() || body.size() > 1024 || body.find('\\') != std::string::npos) return std::nullopt;
  try {
    Json::CharReaderBuilder builder;
    builder["rejectDupKeys"] = true;
    builder["failIfExtra"] = true;
    builder["allowComments"] = false;
    builder["allowTrailingCommas"] = false;
    builder["stackLimit"] = 8;
    std::unique_ptr<Json::CharReader> reader(builder.newCharReader());
    Json::Value value; std::string errors;
    if (!reader->parse(body.data(), body.data() + body.size(), &value, &errors) ||
        !value.isObject() || value["v"].type() != Json::intValue || value["v"].asInt() != 1 ||
        !value["t"].isString() || !Hex(value["conversation"], 40) || !Hex(value["op"], 32)) return std::nullopt;
    const auto type = value["t"].asString();
    std::set<std::string> fields{"v", "t", "conversation", "op"};
    if (type == "ready" || type == "present") {
      fields.insert("nonce"); if (!Hex(value["nonce"], 32)) return std::nullopt;
    } else if (type != "prepare") return std::nullopt;
    if (type == "present") { fields.insert("commit"); if (!Hex(value["commit"], 40)) return std::nullopt; }
    const auto names = value.getMemberNames();
    if (names.size() != fields.size()) return std::nullopt;
    for (const auto& name : names) if (!fields.count(name)) return std::nullopt;
    return Packet{type, value["conversation"].asString(), value["op"].asString(),
                  value.get("nonce", "").asString(), value.get("commit", "").asString()};
  } catch (...) { return std::nullopt; }
}
bool Authorized(const routing::RoutingSnapshot& snapshot, const std::string& account,
                const std::string& peer, const std::string& conversation) {
  if (snapshot.account_id != account || peer.empty() || peer == snapshot.self_id) return false;
  if (snapshot.Group(conversation)) return false;
  const auto route = snapshot.Friend(peer);
  return route && route->confirmed && route->canonical_conversation_id == conversation;
}
} // namespace sybl::hologram
