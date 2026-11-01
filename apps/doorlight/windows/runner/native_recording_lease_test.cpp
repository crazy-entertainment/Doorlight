#ifdef NDEBUG
#undef NDEBUG
#endif
#include "../../third_party/record_windows/windows/native_recording_lease.h"
#include <cassert>
#include <chrono>

using record_windows::NativeRecordingLease;

int main() {
  NativeRecordingLease::Completion late;
  {
    NativeRecordingLease dying([] { return uint64_t{0}; }, [](uint64_t) { return true; });
    dying.SetForeground(true);
    assert(dying.Begin(1, "teardown", [&](auto done) { late = std::move(done); }));
  }
  assert(late);
  late(true);  // No reference to the destroyed authority may be dereferenced.
  late = nullptr;
  uint64_t now = 0, owner = 1;
  NativeRecordingLease leases([&] { return now; }, [&](uint64_t id) { return id == owner; });
  NativeRecordingLease::Completion stopped;
  int stops = 0;
  auto stop = [&](NativeRecordingLease::Completion done) { ++stops; stopped = std::move(done); };
  assert(!leases.Begin(owner, "recorder", stop));
  leases.SetForeground(true);
  auto first = leases.Begin(owner, "recorder", stop);
  assert(first && leases.Current(first));
  assert(!leases.Begin(owner, "parallel", stop));
  now = 2000;
  leases.Tick();
  assert(stops == 1 && leases.Occupied() && !leases.Renew(first));
  auto release = leases.Revoke();
  assert(release.wait_for(std::chrono::milliseconds(0)) == std::future_status::timeout);
  leases.Tick();
  assert(stops == 1);
  stopped(true);
  assert(release.get() && !leases.Occupied());

  auto second = leases.Begin(owner, "second", stop);
  leases.Released(first, true);
  assert(leases.Current(second));
  for (unsigned i = 1; i < 120; ++i) {
    now = second->started + i * 1000;
    assert(leases.Renew(second));
  }
  now = second->started + 120000;
  leases.Tick();
  assert(stops == 2 && !leases.Current(second));
  stopped(true);

  auto third = leases.Begin(owner, "third", stop);
  owner = 2;
  leases.Tick();
  assert(!leases.Current(third) && stops == 3);
  stopped(true);
  auto fourth = leases.Begin(owner, "fourth", stop);
  leases.SetForeground(false);
  leases.SetForeground(true);
  assert(!leases.Current(fourth));
  stopped(true);

  auto fifth = leases.Begin(owner, "fifth", stop);
  auto call = leases.BlockForCall();
  assert(call.wait_for(std::chrono::milliseconds(0)) == std::future_status::timeout);
  stopped(false);
  assert(!call.get() && leases.Occupied());
  leases.ClearCallBlock();
  assert(!leases.Begin(owner, "after-failure", stop));
  stopped(true);
  assert(leases.Occupied());
  return 0;
}
