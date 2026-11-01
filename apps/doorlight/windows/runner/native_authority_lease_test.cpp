#include "native_authority_lease.h"
#include <cassert>
#include <string>
int main() {
  sybl::NativeAuthorityLease<std::string> lease;
  assert(!lease.Current(1000));
  assert(lease.Publish("owner", 1000, 1000));
  assert(!lease.RefreshDue(1099));
  assert(lease.RefreshDue(1100));
  assert(lease.Current(1249) && *lease.Current(1249) == "owner");
  assert(!lease.Current(1250));
  assert(!lease.Current(1250));
  assert(!lease.Publish("stalled", 1000, 1251));
  assert(!lease.Current(1251));
  assert(lease.Publish("fresh", 2000, 2000));
  assert(!lease.Current(1999));
  lease.Clear();
  assert(!lease.Current(2000));
}
