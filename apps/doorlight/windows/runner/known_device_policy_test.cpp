#ifdef NDEBUG
#undef NDEBUG
#endif

#include "known_device_policy.h"

#include <cassert>
#include <map>
#include <string>
#include <iostream>
#include <memory>
#include <stdexcept>

namespace {
using sybl::known_device::RevocationRegistry;
using sybl::known_device::RevocationStatus;
const std::string kDevice(64, 'b');

void TestInitiationWaits(bool accepted) {
  RevocationRegistry registry;
  registry.SelectAccount("account-a");
  const auto first = registry.Begin("account-a", kDevice, 0, {});
  assert(first.ticket != 0);
  bool invoked = false;
  registry.Invoke(first.ticket, 1, [&] { invoked = true; return accepted; });
  assert(invoked);
  assert(registry.TakeReady(2).empty());  // Initiation has no authoritative outcome.
  registry.Ended("account-a", kDevice, 0, 3);
  const auto ready = registry.TakeReady(3);
  assert(ready.size() == 1 && ready[0].result.status == RevocationStatus::kRevoked);
  assert(ready[0].result.account_id == "account-a" && ready[0].result.device_id == kDevice);
}

void TestTimeoutAndLateCallback() {
  RevocationRegistry registry;
  registry.SelectAccount("account-a");
  const auto old = registry.Begin("account-a", kDevice, 0, {});
  registry.Invoke(old.ticket, 1, [] { return true; });
  const auto expired = registry.TakeReady(RevocationRegistry::kTimeoutMs);
  assert(expired.size() == 1 && expired[0].result.status == RevocationStatus::kTimeout);
  assert(registry.Begin("account-a", kDevice, 40'000, {}).status == RevocationStatus::kPending);
  assert(registry.Begin("account-a", kDevice, 40'000, {}).ticket == 0);
  registry.Ended("wrong-account", kDevice, 0, 40'001);
  registry.Ended("account-a", std::string(64, 'c'), 0, 40'001);
  assert(registry.TakeReady(40'001).empty());
  registry.Ended("account-a", kDevice, 0, 40'002);
  assert(registry.TakeReady(40'002).empty());  // It cannot turn the timed-out caller into success.
  const auto retry = registry.Begin("account-a", kDevice, 40'003, {});
  assert(retry.ticket != 0 && retry.ticket != old.ticket);
  registry.Invoke(retry.ticket, 40'004, [] { return false; });
  assert(registry.TakeReady(40'005).empty());
  registry.Ended("account-a", kDevice, 2, 40'006);
  const auto failed = registry.TakeReady(40'006);
  assert(failed.size() == 1 && failed[0].result.status == RevocationStatus::kNetwork);
}

void TestAccountReplacement() {
  RevocationRegistry registry;
  registry.SelectAccount("account-a");
  const auto queued = registry.Begin("account-a", kDevice, 0, {});
  registry.SelectAccount("account-b");
  registry.SelectAccount("account-a");
  bool invoked = false;
  registry.Invoke(queued.ticket, 1, [&] { invoked = true; return true; });
  assert(!invoked);
  const auto cancelled = registry.TakeReady(2);
  assert(cancelled.size() == 1 && cancelled[0].result.status == RevocationStatus::kAccountChanged);
  const auto issued = registry.Begin("account-a", kDevice, 3, {});
  registry.Invoke(issued.ticket, 4, [] { return true; });
  registry.SelectAccount("account-b");
  registry.SelectAccount("account-a");
  const auto retired = registry.TakeReady(5);
  assert(retired.size() == 1 && retired[0].result.status == RevocationStatus::kAccountChanged);
  assert(registry.Begin("account-a", kDevice, 6, {}).ticket == 0);
  registry.Ended("account-a", kDevice, 0, 7);
  assert(registry.TakeReady(7).empty());
}

void TestSynchronousCallbackAndFailure() {
  RevocationRegistry registry;
  registry.SelectAccount("account-a");
  const auto first = registry.Begin("account-a", kDevice, 0, {});
  registry.Invoke(first.ticket, 1, [&] {
    registry.Ended("account-a", kDevice, 1, 1);
    return false;
  });
  auto ready = registry.TakeReady(2);
  assert(ready.size() == 1 && ready[0].result.status == RevocationStatus::kCredentials);
  const auto throwing = registry.Begin("account-a", kDevice, 3, {});
  registry.Invoke(throwing.ticket, 4, []() -> bool { throw std::runtime_error("fixture request failure"); });
  ready = registry.TakeReady(5);
  assert(ready.size() == 1 && ready[0].result.status == RevocationStatus::kUnavailable);
  assert(registry.Begin("account-a", kDevice, 6, {}).ticket == 0);
  registry.Ended("account-a", kDevice, 2, 7);
  assert(registry.TakeReady(7).empty());
}

void TestPreflightAndBounds() {
  RevocationRegistry registry;
  registry.SelectAccount("account-a");
  auto first = registry.Begin("account-a", kDevice, 0, {});
  registry.Refuse(first.ticket, RevocationStatus::kRefused);
  auto ready = registry.TakeReady(1);
  assert(ready.size() == 1 && ready[0].result.status == RevocationStatus::kRefused);
  first = registry.Begin("account-a", kDevice, 2, {});
  bool invoked = false;
  registry.Invoke(first.ticket, 2 + RevocationRegistry::kTimeoutMs,
                  [&] { invoked = true; return true; });
  assert(!invoked);
  ready = registry.TakeReady(40'000);
  assert(ready.size() == 1 && ready[0].result.status == RevocationStatus::kTimeout);
  assert(registry.Begin("different-account", kDevice, 40'001, {}).ticket == 0);
  for (std::size_t i = 0; i < sybl::known_device::kMaxDevices; ++i) {
    const std::string device = std::string(40, 'a') + std::to_string(i);
    assert(registry.Begin("account-a", device, 40'002, {}).ticket != 0);
  }
  assert(registry.Begin("account-a", kDevice, 40'003, {}).ticket == 0);
  registry.Close();
  ready = registry.TakeReady(40'004);
  assert(ready.size() == sybl::known_device::kMaxDevices);
  for (const auto& value : ready) assert(value.result.status == RevocationStatus::kUnavailable);
  assert(registry.Begin("account-a", kDevice, 40'005, {}).ticket == 0);
}

void TestDeadlineAndReplyOwnership() {
  RevocationRegistry registry;
  registry.SelectAccount("account-a");
  auto held = std::make_shared<int>(0);
  const std::weak_ptr<int> lifetime = held;
  const auto first = registry.Begin("account-a", kDevice, 0,
      [held](const auto& result) {
        assert(result.status == RevocationStatus::kTimeout);
        ++*held;
      });
  registry.Invoke(first.ticket, 1, [] { return true; });
  // A late terminal callback cannot beat expiry just because the UI timer has
  // not yet run. Completion uses the callback's monotonic arrival time too.
  registry.Ended("account-a", kDevice, 0, RevocationRegistry::kTimeoutMs + 1);
  auto ready = registry.TakeReady(RevocationRegistry::kTimeoutMs + 2);
  assert(ready.size() == 1 && ready[0].result.status == RevocationStatus::kTimeout);
  ready[0].reply(ready[0].result);
  assert(*held == 1);
  assert(registry.TakeReady(40'000).empty());
  held.reset();
  ready.clear();
  assert(lifetime.expired());

  const auto next = registry.Begin("account-a", kDevice, 40'001, {});
  assert(next.ticket != 0);
  bool invoked = false;
  registry.Invoke(first.ticket, 40'002, [&] { invoked = true; return true; });
  assert(!invoked);  // A stale worker closure cannot issue the new operation.
  const auto independent = registry.Begin("account-a", std::string(64, 'c'), 40'003, {});
  assert(independent.ticket != 0);
  registry.Invoke(independent.ticket, 40'004, [&] {
    registry.Ended("account-a", std::string(64, 'c'), 0, 40'004);
    return false;
  });
  ready = registry.TakeReady(40'005);
  assert(ready.size() == 1 && ready[0].result.device_id == std::string(64, 'c') &&
         ready[0].result.status == RevocationStatus::kRevoked);
  registry.Close();
  ready = registry.TakeReady(40'006);
  assert(ready.size() == 1 && ready[0].result.device_id == kDevice &&
         ready[0].result.status == RevocationStatus::kUnavailable);
}
}  // namespace

int main(int argc, char** argv) {
  if (argc > 2) return 2;
  if (argc == 2) {
    const std::string selected = argv[1];
    if (selected == "initiation-true") TestInitiationWaits(true);
    else if (selected == "initiation-false") TestInitiationWaits(false);
    else if (selected == "timeout") TestTimeoutAndLateCallback();
    else if (selected == "account-replacement") TestAccountReplacement();
    else return 2;
    std::cout << "Known device case passed: " << selected << '\n';
    return 0;
  }
  using sybl::known_device::BoundedName;
  using sybl::known_device::CanRevoke;
  using sybl::known_device::IsDeviceId;
  using sybl::known_device::Project;

  const std::string current(40, 'a');
  const std::string other(64, 'b');
  const std::map<std::string, std::string> known{
      {current, " This PC "},
      {other, "Phone"},
      {"not-a-device", "Bad"},
  };

  const auto devices = Project(known, current);
  assert(devices.size() == 2);
  assert(devices[0].id == current);
  assert(devices[0].name == "This PC");
  assert(devices[0].current);
  assert(devices[1].id == other);
  assert(!devices[1].current);

  assert(IsDeviceId(current));
  assert(!IsDeviceId(std::string(39, 'a')));
  assert(!IsDeviceId(std::string(40, 'A')));
  assert(!IsDeviceId("../" + other));
  assert(BoundedName("bad\nname").empty());
  assert(BoundedName(std::string(129, 'x')).empty());
  assert(BoundedName("\xf0\x9f\x98\x80") == "\xf0\x9f\x98\x80");
  assert(BoundedName("\xc0\xaf").empty());

  assert(CanRevoke(other, current, known));
  assert(!CanRevoke(current, current, known));
  assert(!CanRevoke(current, "", known));
  assert(!CanRevoke(other, "", known));
  assert(!CanRevoke(other, "unavailable", known));
  assert(!CanRevoke(std::string(40, 'b'), current, known));
  TestInitiationWaits(true);
  TestInitiationWaits(false);
  TestTimeoutAndLateCallback();
  TestAccountReplacement();
  TestSynchronousCallbackAndFailure();
  TestPreflightAndBounds();
  TestDeadlineAndReplyOwnership();
  std::cout << "Known device policy tests passed.\n";
  return 0;
}
