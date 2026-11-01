#pragma once

#include <string>

namespace sybl::remote {

enum class LocalIcePath {
  kUnknown,
  kHostToHost,
  kServerReflexive,
  kPeerReflexive,
  kRelay,
};

struct LocalIceObservation {
  LocalIcePath path = LocalIcePath::kUnknown;
  std::string local_address;
  std::string remote_address;
};

// Parses the local daemon's Call::Details::SOCKETS / dhtnet link() output.
// This observation is local policy input and must never be accepted from wire
// data.
LocalIceObservation ParseLocalIceObservation(const std::string& sockets);
LocalIcePath ParseLocalIcePath(const std::string& sockets);

// Automatic co-control requires both a selected host-to-host ICE pair and a
// separately proven same-adapter private prefix. The latter is deliberately
// not inferred from the ICE candidate type because host candidates can contain
// globally routed addresses.
bool DefaultCoControlForPath(LocalIcePath path,
                             bool same_lan_prefix_proven,
                             bool exact_device_persistent);

}  // namespace sybl::remote
