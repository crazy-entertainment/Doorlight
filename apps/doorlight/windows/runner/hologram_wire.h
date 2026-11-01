#pragma once
#include "friend_routing.h"
#include <optional>
#include <string>

namespace sybl::hologram {
inline constexpr char kMime[] = "application/x-sybl-hologram-live+json";
struct Packet { std::string type, conversation, operation, nonce, commit; };
std::optional<Packet> Decode(const std::string& body);
bool Authorized(const routing::RoutingSnapshot& snapshot, const std::string& account,
                const std::string& peer, const std::string& conversation);
} // namespace sybl::hologram
