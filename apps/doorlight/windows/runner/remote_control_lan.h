#pragma once

#include "remote_control_ice.h"

#include <cstdint>
#include <string>
#include <vector>

namespace sybl::remote {

struct LocalAdapterPrefix {
  std::string address;
  std::uint8_t prefix_length = 0;
  std::uint32_t scope_id = 0;
};

// A host/host ICE pair is considered local only when both selected addresses
// are private/link-local and share the prefix of the actual local adapter that
// owns the selected local address. Unparseable and global addresses fail
// closed.
bool IsProvenSameLan(
    const LocalIceObservation& observation,
    const std::vector<LocalAdapterPrefix>& local_prefixes);

// Takes a point-in-time snapshot of operational Windows unicast adapters.
std::vector<LocalAdapterPrefix> CurrentLocalAdapterPrefixes();

}  // namespace sybl::remote
