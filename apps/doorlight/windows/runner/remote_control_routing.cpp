#include "remote_control_routing.h"

#include <algorithm>
#include <cctype>

namespace sybl::remote {
namespace {

bool IsLowerHex(const std::string& value, std::size_t length) {
  return value.size() == length &&
      std::all_of(value.begin(), value.end(), [](unsigned char c) {
        return std::isdigit(c) || (c >= 'a' && c <= 'f');
      });
}

bool IsLowerHexRange(const std::string& value,
                     std::size_t minimum,
                     std::size_t maximum) {
  return value.size() >= minimum && value.size() <= maximum &&
      std::all_of(value.begin(), value.end(), [](unsigned char c) {
        return std::isdigit(c) || (c >= 'a' && c <= 'f');
      });
}

}  // namespace

bool AuthenticatedControlPeerMatches(const std::string& signaling_account,
                                     const std::string& certificate_account,
                                     const std::string& certificate_device,
                                     const std::string& admitted_call_peer) {
  return IsLowerHex(signaling_account, 40) &&
      IsLowerHex(certificate_account, 40) &&
      IsLowerHexRange(certificate_device, 40, 128) &&
      IsLowerHex(admitted_call_peer, 40) &&
      signaling_account == certificate_account &&
      certificate_account == admitted_call_peer;
}

}  // namespace sybl::remote
