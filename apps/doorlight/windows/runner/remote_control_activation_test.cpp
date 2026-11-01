#ifdef NDEBUG
#undef NDEBUG
#endif

#include "remote_control_activation.h"

#include <cassert>

using namespace sybl::remote;

int main() {
  ConsentActivation activation;
  assert(!activation.pending());
  assert(!activation.Begin(0));
  assert(activation.Begin(7));
  assert(activation.pending() && activation.generation() == 7);
  assert(!activation.Begin(8));

  // A stale completion must not consume the current transaction.
  const auto stale = activation.Commit(6);
  assert(!stale.current &&
         stale.reason == ActivationAbortReason::kSuperseded);
  assert(activation.pending() && activation.generation() == 7);

  // A lifecycle cancellation must beat the matching UI-thread completion.
  assert(activation.Cancel(ActivationAbortReason::kCallEnded));
  assert(activation.Cancel(ActivationAbortReason::kShutdown));
  const auto canceled = activation.Commit(7);
  assert(!canceled.current &&
         canceled.reason == ActivationAbortReason::kCallEnded);
  assert(!activation.pending());

  assert(activation.Begin(8));
  const auto committed = activation.Commit(8);
  assert(committed.current &&
         committed.reason == ActivationAbortReason::kNone);
  assert(!activation.pending());

  assert(activation.Begin(9));
  assert(activation.Cancel(ActivationAbortReason::kLocalStop));
  activation.Clear();
  assert(!activation.pending());
  assert(!activation.Cancel(ActivationAbortReason::kSourceChanged));
}
