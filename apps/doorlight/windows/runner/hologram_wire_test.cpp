#include "hologram_wire.h"
#include <cassert>
#include <iostream>

int main() {
  using namespace sybl;
  const std::string conv(40, 'a'), peer(40, 'b'), op(32, 'c');
  const auto prepare = "{\"v\":1,\"t\":\"prepare\",\"conversation\":\"" + conv + "\",\"op\":\"" + op + "\"}";
  assert(hologram::Decode(prepare));
  auto ready = prepare; ready.replace(ready.find("prepare"), 7, "ready");
  ready.pop_back(); ready += ",\"nonce\":\"" + op + "\"}";
  assert(hologram::Decode(ready)->nonce == op);
  auto present = ready; present.replace(present.find("ready"), 5, "present");
  present.pop_back(); present += ",\"commit\":\"" + conv + "\"}";
  assert(hologram::Decode(present)->commit == conv);
  for (const auto& suffix : {"junk", "{}", "/*comment*/"}) assert(!hologram::Decode(prepare + suffix));
  assert(!hologram::Decode(prepare.substr(0, prepare.size()-1) + ",}"));
  for (const auto& version : {"1.0", "1e0", "true", "2", "1,\"v\":1"}) {
    auto bad = prepare; bad.replace(5, 1, version); assert(!hologram::Decode(bad));
  }
  auto escaped = prepare; escaped.replace(1, 3, "\"\\u0076\"");
  assert(!hologram::Decode(escaped));
  assert(!hologram::Decode(std::string(1025, 'x')));
  routing::RoutingSnapshot snapshot;
  snapshot.account_id = "account"; snapshot.self_id = std::string(40, 'd');
  snapshot.friends[peer] = {peer, true, conv, {conv}};
  assert(hologram::Authorized(snapshot, "account", peer, conv));
  assert(!hologram::Authorized(snapshot, "other", peer, conv));
  assert(!hologram::Authorized(snapshot, "account", snapshot.self_id, conv));
  assert(!hologram::Authorized(snapshot, "account", peer, std::string(40, 'e')));
  snapshot.friends[peer].confirmed = false;
  assert(!hologram::Authorized(snapshot, "account", peer, conv));
  snapshot.friends[peer].confirmed = true;
  snapshot.groups[conv].active_member_ids.insert(peer);
  snapshot.groups[conv].local_role = "member";
  assert(!hologram::Authorized(snapshot, "account", peer, conv));
  std::cout << "Hologram wire and direct routing passed\n";
}
