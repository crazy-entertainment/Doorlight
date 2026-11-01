#pragma once

#include <string>

namespace sybl::remote {

// All values are already normalized by the bridge. Remote-control authority
// requires the signaling label, transport certificate, and native call
// admission record to identify the same account. The device is exclusively
// certificate-derived and must never come from a message payload.
bool AuthenticatedControlPeerMatches(const std::string& signaling_account,
                                     const std::string& certificate_account,
                                     const std::string& certificate_device,
                                     const std::string& admitted_call_peer);

}  // namespace sybl::remote
