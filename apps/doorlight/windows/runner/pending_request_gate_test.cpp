#ifdef NDEBUG
#undef NDEBUG
#endif

#include "pending_request_gate.h"

#include <cassert>

int main() {
  sybl::PendingRequestGate gate(2, 2, 100);
  assert(gate.Admit("a", 0) == sybl::PendingRequestAdmission::kNew);
  assert(gate.Admit("a", 1) == sybl::PendingRequestAdmission::kDuplicate);
  assert(gate.Admit("b", 2) == sybl::PendingRequestAdmission::kNew);
  assert(gate.Admit("c", 3) == sybl::PendingRequestAdmission::kRejected);
  assert(gate.Remove("a"));
  assert(gate.Restore("a"));
  assert(!gate.Restore("c"));
  assert(gate.Remove("a"));
  assert(gate.Admit("c", 100) == sybl::PendingRequestAdmission::kNew);
  gate.Clear();
  assert(gate.Admit("d", 101) == sybl::PendingRequestAdmission::kNew);
  assert(gate.Contains("d"));
  assert(gate.Remove("d"));
  assert(!gate.Contains("d"));
  return 0;
}
