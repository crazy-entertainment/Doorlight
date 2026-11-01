#include "stage_registry.h"
#include <cassert>

int main() {
  using namespace sybl::stage;
  std::optional<std::string> saved;
  auto persist = [&](const std::string& value) { saved = value; return true; };
  Registry registry(std::nullopt, persist);
  assert(registry.ReserveRecording("voice"));
  assert(!registry.OwnsIssued("voice"));
  Record issued {"voice", "account", "peer", "conversation", std::string(32, 'a'), false};
  assert(registry.Issue(issued));
  assert(registry.OwnsIssued("voice"));
  Registry restarted(saved, persist);
  assert(restarted.healthy());
  assert(restarted.Find(issued.operation)->recording);
  assert(restarted.OwnsIssued("voice"));
  assert(!restarted.Issue(issued));
  issued.path = "other";
  assert(!restarted.Issue(issued));
  assert(restarted.Forget("voice"));
  assert(!restarted.Find(issued.operation));
  Registry corrupt(std::string("broken"), persist);
  assert(!corrupt.healthy());
  assert(corrupt.OwnsIssued("anything"));
  assert(!corrupt.ReserveRecording("anything"));
  Registry failed(std::nullopt, [](const auto&) { return false; });
  assert(!failed.ReserveRecording("voice"));
  assert(!failed.healthy());
  assert(failed.OwnsIssued("voice"));
  Registry bounded(std::nullopt, persist);
  for (int i = 0; i < 256; ++i) assert(bounded.ReserveRecording("voice" + std::to_string(i)));
  assert(!bounded.ReserveRecording("overflow"));
  assert(bounded.records().size() == 256);
}
