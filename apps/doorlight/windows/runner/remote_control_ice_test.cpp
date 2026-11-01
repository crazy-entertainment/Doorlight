#ifdef NDEBUG
#undef NDEBUG
#endif

#include "remote_control_ice.h"

#include <cassert>
#include <string>

using namespace sybl::remote;

int main() {
  const std::string host =
      " [1] 192.168.1.5:5000 [host] \xE2\x86\x94 "
      "192.168.1.9:5001 [host] \n";
  assert(ParseLocalIcePath(host) == LocalIcePath::kHostToHost);
  const auto observation = ParseLocalIceObservation(host);
  assert(observation.path == LocalIcePath::kHostToHost);
  assert(observation.local_address == "192.168.1.5");
  assert(observation.remote_address == "192.168.1.9");
  assert(DefaultCoControlForPath(ParseLocalIcePath(host), true, true));
  assert(!DefaultCoControlForPath(ParseLocalIcePath(host), false, true));
  assert(!DefaultCoControlForPath(ParseLocalIcePath(host), true, false));

  const std::string ipv6 =
      " [1] [fe80::1]:5000 [host] \xE2\x86\x94 "
      "[fe80::2]:5001 [host] \r\n";
  assert(ParseLocalIcePath(ipv6) == LocalIcePath::kHostToHost);

  const std::string srflx =
      " [1] 203.0.113.1:5000 [srflx] \xE2\x86\x94 "
      "192.168.1.9:5001 [host] \n";
  assert(ParseLocalIcePath(srflx) == LocalIcePath::kServerReflexive);
  assert(!DefaultCoControlForPath(ParseLocalIcePath(srflx), true, true));

  const std::string prflx =
      " [1] 203.0.113.1:5000 [prflx] \xE2\x86\x94 "
      "192.168.1.9:5001 [host] \n";
  assert(ParseLocalIcePath(prflx) == LocalIcePath::kPeerReflexive);
  assert(!DefaultCoControlForPath(ParseLocalIcePath(prflx), true, true));

  const std::string relay =
      " [1] 192.168.1.5:5000 [host] \xE2\x86\x94 "
      "203.0.113.4:6000 [relay] \n";
  assert(ParseLocalIcePath(relay) == LocalIcePath::kRelay);
  assert(!DefaultCoControlForPath(ParseLocalIcePath(relay), true, true));

  const std::string mixed =
      host +
      " [2] 192.168.1.5:5002 [host] \xE2\x86\x94 "
      "203.0.113.4:6002 [relay] \n";
  assert(ParseLocalIcePath(mixed) == LocalIcePath::kRelay);
  assert(ParseLocalIceObservation(mixed).local_address.empty());

  for (const auto& malformed : {
           std::string(),
           std::string(" [1] disabled\n"),
           std::string(" [1] a [host] -> b [host]\n"),
           std::string(" [1] a [host] \xE2\x86\x94 b [host]\n"),
           std::string(" [1] a [unknown] \xE2\x86\x94 b [host]\n"),
           std::string(" [1] a [host] \xE2\x86\x94 b [host] extra\n"),
           std::string(" [1] a [host] \xE2\x86\x94 b [host]\n"
                       " [1] c [host] \xE2\x86\x94 d [host]\n"),
           std::string("\n"),
       }) {
    assert(ParseLocalIcePath(malformed) == LocalIcePath::kUnknown);
    assert(!DefaultCoControlForPath(ParseLocalIcePath(malformed), true, true));
  }
  assert(!DefaultCoControlForPath(LocalIcePath::kUnknown, true, true));
}
