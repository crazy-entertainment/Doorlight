#ifdef NDEBUG
#undef NDEBUG
#endif

#include "remote_control_routing.h"

#include <cassert>
#include <string>

using sybl::remote::AuthenticatedControlPeerMatches;

int main() {
  const std::string account(40, 'a');
  const std::string other(40, 'b');
  const std::string device(64, '1');

  assert(AuthenticatedControlPeerMatches(account, account, device, account));
  assert(AuthenticatedControlPeerMatches(account, account,
                                         std::string(40, '2'), account));
  assert(!AuthenticatedControlPeerMatches(other, account, device, account));
  assert(!AuthenticatedControlPeerMatches(account, other, device, account));
  assert(!AuthenticatedControlPeerMatches(account, account, device, other));
  assert(!AuthenticatedControlPeerMatches(account, account, "", account));
  assert(!AuthenticatedControlPeerMatches(std::string(40, 'A'), account,
                                          device, account));
  assert(!AuthenticatedControlPeerMatches(account, account,
                                          std::string(64, 'g'), account));
}
