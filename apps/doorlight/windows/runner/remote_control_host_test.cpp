#ifdef NDEBUG
#undef NDEBUG
#endif

#include "remote_control_host.h"
#include "remote_control_host_channel.h"
#include "send_input_observer_test_support.h"

#include <algorithm>
#include <atomic>
#include <cassert>
#include <chrono>
#include <condition_variable>
#include <cstdio>
#include <future>
#include <mutex>
#include <thread>
#include <utility>
#include <vector>

using namespace sybl::remote;
using namespace std::chrono_literals;

namespace sybl::remote {
struct RemoteControlHostTestAccess {
  static bool HostMutexAvailable(RemoteControlHost& host) {
    if (!host.mutex_.try_lock()) return false;
    host.mutex_.unlock();
    return true;
  }
};
}  // namespace sybl::remote

namespace {

constexpr auto kAccount = "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa";
constexpr auto kLocal = "bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb";
constexpr auto kDevice =
    "1111111111111111111111111111111111111111111111111111111111111111";
constexpr Capabilities kCapabilities = CapabilityBit(Capability::kKeyboard) |
    CapabilityBit(Capability::kMouse) | CapabilityBit(Capability::kText);
constexpr UINT kAutoAllowMessage = WM_APP + 0x238;
std::atomic<std::uint64_t> import_calls{0};

bool IsRelease(const INPUT& value) {
  return (value.type == INPUT_KEYBOARD &&
          (value.ki.dwFlags & KEYEVENTF_KEYUP) != 0) ||
      (value.type == INPUT_MOUSE &&
       (value.mi.dwFlags & (MOUSEEVENTF_LEFTUP | MOUSEEVENTF_RIGHTUP |
                           MOUSEEVENTF_MIDDLEUP | MOUSEEVENTF_XUP)) != 0);
}

// A bounded barrier makes pending native work observable without sending input
// to Windows or relying on sleeps to choose an interleaving.
class Barrier {
 public:
  void Enter() {
    std::unique_lock<std::mutex> lock(mutex_);
    entered_ = true;
    changed_.notify_all();
    assert(changed_.wait_for(lock, 10s, [this] { return released_; }));
  }
  void Wait() {
    std::unique_lock<std::mutex> lock(mutex_);
    assert(changed_.wait_for(lock, 10s, [this] { return entered_; }));
  }
  void Release() {
    std::lock_guard<std::mutex> lock(mutex_);
    released_ = true;
    changed_.notify_all();
  }

 private:
  std::mutex mutex_;
  std::condition_variable changed_;
  bool entered_ = false;
  bool released_ = false;
};

class FakeSafety final : public ProcessPrivilegeProbe,
                         public InputDesktopProbe,
                         public BannerVisibilityProbe {
 public:
  SafetyObservation Observe() override { return observation.load(); }
  std::atomic<SafetyObservation> observation{SafetyObservation::kSafe};
};

class FakeCrypto final : public SecretSource, public HashProvider {
 public:
  std::optional<std::string> GenerateHex(std::size_t bytes) override {
    assert(bytes == 16);
    if (generation_barrier) generation_barrier->Enter();
    std::string value(32, 'a');
    value.back() = static_cast<char>('0' + ++generation);
    return value;
  }
  std::optional<std::string> Sha256Hex(std::string_view) override {
    return std::string(64, 'a');
  }
  Barrier* generation_barrier = nullptr;
  int generation = 0;
};

class FakeHotkey final : public KillHotkeyRegistrar {
 public:
  bool Register(HWND, int, UINT, UINT) override { return true; }
  bool Unregister(HWND, int) override { return true; }
};

class FakeRaw final : public RawInputMonitor {
 public:
  bool Register(HWND) override { return true; }
  void Unregister() override {}
  RawInputOrigin Classify(LPARAM) override { return RawInputOrigin::kInjected; }
};

class FakeClock final : public MonotonicClock {
 public:
  std::uint64_t NowMs() override { return now.load(); }
  std::atomic<std::uint64_t> now{1000};
};

class MemoryStorage final : public GrantBlobStorage {
 public:
  ReadResult Read() override {
    return bytes.empty() ? ReadResult{ReadStatus::kAbsent, {}}
                         : ReadResult{ReadStatus::kLoaded, bytes};
  }
  bool Write(const std::string& value) override {
    bytes = value;
    if (after_write) after_write();
    return true;
  }
  bool Remove() override {
    if (fail_remove) return false;
    bytes.clear();
    return true;
  }
  std::string bytes;
  std::function<void()> after_write;
  bool fail_remove = false;
};

class MemoryProtector final : public GrantBlobProtector {
 public:
  std::optional<std::string> Protect(const std::string& value) override {
    return value;
  }
  std::optional<std::string> Unprotect(const std::string& value) override {
    return value;
  }
};

struct Harness {
  FakeSafety privilege;
  FakeSafety desktop;
  FakeSafety banner;
  FakeCrypto crypto;
  FakeHotkey hotkey;
  FakeRaw raw;
  FakeClock clock;
  MemoryStorage storage;
  MemoryProtector protector;
  PersistentGrantStore grants{storage, protector};
  std::mutex observed_mutex;
  std::vector<INPUT> os_calls;
  std::vector<Message> sent;
  std::vector<std::pair<std::string, std::map<std::string, std::string>>> events;
  std::atomic<bool> release_ok{true};
  std::atomic<bool> send_ok{true};
  std::atomic<bool> authority_ok{true};
  std::atomic<bool> surface_ok{true};
  ResolvedSurface current_surface{
      {0, 0, 1920, 1080}, {0, 0, 1920, 1080}, L"TEST-DISPLAY"};
  std::optional<POINT> cursor_position = POINT{100, 200};
  std::function<void()> on_cursor_query;
  Barrier* input_barrier = nullptr;
  Barrier* release_barrier = nullptr;
  std::function<void(const INPUT&)> on_input;
  test::ScopedSendInputObserver input_observer;
  std::unique_ptr<RemoteControlHost> host;
  InboundControlEnvelope envelope;
  std::uint64_t channel_epoch = 0;
  std::uint64_t surface_revision = 1;
  Capabilities request_capabilities = kCapabilities;

  explicit Harness(bool connect = true)
      : input_observer([this](UINT count, LPINPUT inputs, int size) -> UINT {
          assert(count == 1 && inputs && size == sizeof(INPUT));
          ++import_calls;
          const INPUT value = inputs[0];
          const bool release = IsRelease(value);
          {
            std::lock_guard<std::mutex> lock(observed_mutex);
            os_calls.push_back(value);
          }
          if (release && release_barrier) release_barrier->Enter();
          if (!release && input_barrier) input_barrier->Enter();
          if (on_input) on_input(value);
          return !release || release_ok.load() ? 1U : 0U;
        }) {
    envelope.account_id = "local-account";
    envelope.call_id = "call-a";
    envelope.controller_account = kAccount;
    envelope.controller_device = kDevice;
    envelope.source_uri = "display://test";
    envelope.source_revision = 7;
    envelope.source_width = 1920;
    envelope.source_height = 1080;
    envelope.local_jami_id = kLocal;
    HostDependencies dependencies;
    dependencies.secrets = &crypto;
    dependencies.hashes = &crypto;
    dependencies.process_privilege = &privilege;
    dependencies.desktop = &desktop;
    dependencies.banner = &banner;
    dependencies.hotkey = &hotkey;
    dependencies.raw_input = &raw;
    dependencies.clock = &clock;
    dependencies.grants = &grants;
    dependencies.cursor_position = [this] {
      if (on_cursor_query) on_cursor_query();
      return cursor_position;
    };
    dependencies.resolve_surface = [this](const InboundControlEnvelope&) {
      return surface_ok.load()
          ? std::optional<ResolvedSurface>(current_surface)
          : std::nullopt;
    };
    dependencies.show_banner = [](RuntimeState, RuntimeReason,
                                 const std::string&,
                                 std::optional<DesktopRect>) {};
    host = std::make_unique<RemoteControlHost>(
        reinterpret_cast<HWND>(1),
        [this](const std::string&, const std::string& packet) {
          const auto parsed = ParsePacket(
              packet, WireDirection::kControlleeToController);
          assert(parsed);
          std::lock_guard<std::mutex> lock(observed_mutex);
          sent.push_back(*parsed.message);
          return send_ok.load();
        },
        [this](const std::string& type,
               const std::map<std::string, std::string>& fields) {
          std::lock_guard<std::mutex> lock(observed_mutex);
          events.emplace_back(type, fields);
        },
        [this](const InboundControlEnvelope&) { return authority_ok.load(); },
        dependencies);
    if (connect) {
      channel_epoch = host->ResetAuthorityChannel(true).channel_epoch;
      const auto status =
          host->SetProtectedSurface(channel_epoch, surface_revision, false);
      assert(!status.blocked && status.state == "inactive");
    }
  }

  ~Harness() {
    // The host must finish its cleanup while its import observer and evidence
    // stores still exist. No asynchronous fixture work survives this point.
    host.reset();
    assert(input_observer.calls() == os_calls.size());
  }

  void Receive(const Message& message,
               std::optional<InboundControlEnvelope> source = std::nullopt) {
    auto current = source.value_or(envelope);
    const auto wire =
        SerializePacket(message, WireDirection::kControllerToControllee);
    assert(wire);
    current.payload = wire.packet;
    host->OnControlMessage(std::move(current));
  }

  std::uint64_t Request() {
    std::size_t previous_events = 0;
    {
      std::lock_guard<std::mutex> lock(observed_mutex);
      previous_events = events.size();
    }
    Receive(Message{
        RequestMessage{request_capabilities, envelope.source_revision}});
    std::lock_guard<std::mutex> lock(observed_mutex);
    for (auto i = previous_events; i < events.size(); ++i) {
      if (events[i].first == "remoteControlRequest")
        return std::stoull(events[i].second.at("hostGeneration"));
    }
    return 0;
  }

  LocalControlResult Allow(std::uint64_t generation, bool persist = false) {
    return persist
        ? host->AllowDevice(envelope.call_id, envelope.controller_account,
                            envelope.controller_device,
                            envelope.source_revision, generation)
        : host->AllowOnce(envelope.call_id, envelope.controller_account,
                          envelope.controller_device,
                          envelope.source_revision, generation);
  }

  GrantMessage Establish(bool persist = false) {
    const auto permission =
        host->SetProtectedSurface(channel_epoch, ++surface_revision, false);
    assert(!permission.blocked);
    const auto generation = Request();
    assert(generation != 0);
    const auto allowed = Allow(generation, persist);
    if (allowed != LocalControlResult::kApplied) {
      std::fprintf(stderr, "Allow failed for %s: result=%d state=%s blocked=%d\n",
                   envelope.call_id.c_str(), static_cast<int>(allowed),
                   host->AuthorityStatus().state.c_str(),
                   host->AuthorityStatus().blocked);
    }
    assert(allowed == LocalControlResult::kApplied);
    const auto status = host->AuthorityStatus();
    assert(status.state == "active" && status.host_generation == generation);
    std::lock_guard<std::mutex> lock(observed_mutex);
    for (auto it = sent.rbegin(); it != sent.rend(); ++it) {
      if (const auto* grant = std::get_if<GrantMessage>(&*it)) return *grant;
    }
    assert(false && "Allow must publish a matching native grant");
    return {};
  }

  void Input(const GrantMessage& grant, std::uint64_t sequence,
             std::vector<InputEvent> events) {
    Receive(Message{InputMessage{grant.token, grant.epoch, sequence,
                                 grant.source_revision, std::move(events)}});
  }

  std::size_t DownCalls() {
    std::lock_guard<std::mutex> lock(observed_mutex);
    return static_cast<std::size_t>(std::count_if(
        os_calls.begin(), os_calls.end(), [](const INPUT& value) {
          return value.type == INPUT_KEYBOARD &&
              (value.ki.dwFlags & KEYEVENTF_KEYUP) == 0;
        }));
  }

  std::size_t GrantCount() {
    std::lock_guard<std::mutex> lock(observed_mutex);
    return static_cast<std::size_t>(std::count_if(
        sent.begin(), sent.end(), [](const Message& message) {
          return std::holds_alternative<GrantMessage>(message);
        }));
  }

  HostAuthorityStatus Block() {
    return host->SetProtectedSurface(channel_epoch, ++surface_revision, true);
  }

  void WaitForBlockAdmission() {
    const auto deadline = std::chrono::steady_clock::now() + 10s;
    // A source-mismatched request is unsupported while input is allowed, but
    // receives busy at the initial native block guard. This observes block
    // intent without waiting for the runtime lock held by an in-flight input.
    for (;;) {
      Receive(Message{RequestMessage{kCapabilities, envelope.source_revision + 1}});
      {
        std::lock_guard<std::mutex> lock(observed_mutex);
        assert(!sent.empty());
        if (const auto* denied = std::get_if<DenyMessage>(&sent.back())) {
          if (denied->reason == DenyReason::kBusy) return;
          assert(denied->reason == DenyReason::kUnsupported);
        } else {
          assert(false && "block probe must receive a denial");
        }
      }
      assert(std::chrono::steady_clock::now() < deadline);
      std::this_thread::yield();
    }
  }
};

void NormalStopAcknowledgesReleaseAndRejectsLateInput() {
  Harness h;
  const auto grant = h.Establish();
  h.Input(grant, 1, {KeyEvent{'A', true}});
  assert(h.DownCalls() == 1);
  assert(h.host->Stop());
  auto status = h.host->AuthorityStatus();
  assert(status.state == "inactive" && status.release_complete);
  assert(status.revoked_through != 0);
  assert(h.os_calls.size() == 2);
  assert((h.os_calls.back().ki.dwFlags & KEYEVENTF_KEYUP) != 0);
  assert(h.host->Stop());
  assert(h.os_calls.size() == 2);
  h.Input(grant, 2, {KeyEvent{'B', true}});
  assert(h.DownCalls() == 1);
}

void ChangedTopologyRejectsMouseBeforeSafetyPoll() {
  Harness h;
  const auto grant = h.Establish();
  h.surface_ok = false;
  h.Input(grant, 1, {ButtonEvent{MouseButton::kLeft, true}});
  assert(h.os_calls.empty());
  assert(h.host->AuthorityStatus().state == "inactive");
}

void MouseChecksExactSurfaceBetweenOperations() {
  for (int mutation = 0; mutation < 3; ++mutation) {
    Harness h;
    const auto grant = h.Establish();
    h.on_input = [&](const INPUT& input) {
      if (input.type != INPUT_MOUSE || (input.mi.dwFlags & MOUSEEVENTF_LEFTDOWN) == 0)
        return;
      if (mutation == 0) h.current_surface.device = L"REPLACEMENT-DISPLAY";
      if (mutation == 1) h.current_surface.virtual_desktop.left = -1920;
      if (mutation == 2) h.current_surface.source.left = 1920;
    };
    h.Input(grant, 1, {ButtonEvent{MouseButton::kLeft, true}, WheelEvent{120}});
    assert(h.os_calls.size() == 2);  // First down and owed cleanup up only.
    assert((h.os_calls.front().mi.dwFlags & MOUSEEVENTF_LEFTDOWN) != 0);
    assert(h.os_calls.back().mi.dwFlags == MOUSEEVENTF_LEFTUP);
    assert(h.host->AuthorityStatus().state == "inactive");
    assert(h.host->AuthorityStatus().release_complete);
  }
}

void MouseSurfaceCheckCannotDeadlockClipboardAdmission() {
  Harness h;
  const auto grant = h.Establish();
  Barrier cursor_query;
  h.on_cursor_query = [&] { cursor_query.Enter(); };
  auto mouse = std::async(std::launch::async, [&] {
    h.Input(grant, 1, {ButtonEvent{MouseButton::kLeft, true}});
  });
  cursor_query.Wait();  // Mouse drain owns the runtime mutex.
  auto clipboard = std::async(std::launch::async, [&] {
    return h.host->SendClipboard(
        "synthetic clipboard offer", h.envelope.call_id,
        h.envelope.controller_account, h.envelope.controller_device,
        h.envelope.source_revision, 1);
  });
  const auto deadline = std::chrono::steady_clock::now() + 10s;
  while (RemoteControlHostTestAccess::HostMutexAvailable(*h.host)) {
    assert(clipboard.wait_for(0ms) != std::future_status::ready);
    assert(std::chrono::steady_clock::now() < deadline);
    std::this_thread::yield();
  }
  // The clipboard path owns the host mutex and waits for runtime. Mouse
  // source validation must not acquire that host mutex in the opposite order.
  cursor_query.Release();
  assert(mouse.wait_for(2s) == std::future_status::ready);
  assert(clipboard.wait_for(2s) == std::future_status::ready);
  mouse.get();
  assert(clipboard.get() == LocalControlResult::kStale);  // No clipboard grant.
  h.on_cursor_query = {};
  assert(h.os_calls.size() == 1);
  assert((h.os_calls[0].mi.dwFlags & MOUSEEVENTF_LEFTDOWN) != 0);
}

LocalControlResult SendOwned(Harness& h, std::uint64_t generation) {
  return h.host->SendClipboard(
      "synthetic clipboard offer", h.envelope.call_id,
      h.envelope.controller_account, h.envelope.controller_device,
      h.envelope.source_revision, generation);
}

std::size_t ClipboardOffers(Harness& h) {
  std::lock_guard<std::mutex> lock(h.observed_mutex);
  return static_cast<std::size_t>(std::count_if(
      h.sent.begin(), h.sent.end(), [](const Message& message) {
        return std::holds_alternative<ClipboardOfferMessage>(message);
      }));
}

void ClipboardSendRequiresTheCapturedHostSession() {
  Harness h;
  h.request_capabilities |= CapabilityBit(Capability::kClipboard);
  h.Establish();
  const auto generation = h.host->AuthorityStatus().host_generation;
  assert(generation != 0);

  // A different generation of the same call, peer and revision is stale.
  assert(SendOwned(h, generation + 1) == LocalControlResult::kStale);
  assert(SendOwned(h, 0) == LocalControlResult::kStale);
  // A different binding under the live generation is stale.
  assert(h.host->SendClipboard("synthetic clipboard offer", "call-other",
                               h.envelope.controller_account,
                               h.envelope.controller_device,
                               h.envelope.source_revision, generation) ==
         LocalControlResult::kStale);
  assert(h.host->SendClipboard("synthetic clipboard offer", h.envelope.call_id,
                               h.envelope.controller_account,
                               "2222222222222222222222222222222222222222222222222222222222222222",
                               h.envelope.source_revision, generation) ==
         LocalControlResult::kStale);
  assert(h.host->SendClipboard("synthetic clipboard offer", h.envelope.call_id,
                               h.envelope.controller_account,
                               h.envelope.controller_device,
                               h.envelope.source_revision + 1, generation) ==
         LocalControlResult::kStale);
  assert(ClipboardOffers(h) == 0);

  assert(SendOwned(h, generation) == LocalControlResult::kApplied);
  assert(ClipboardOffers(h) == 1);
}

void ClipboardSendAfterTheSessionEndedIsStale() {
  Harness h;
  h.request_capabilities |= CapabilityBit(Capability::kClipboard);
  h.Establish();
  const auto generation = h.host->AuthorityStatus().host_generation;
  assert(h.host->Stop());
  assert(SendOwned(h, generation) == LocalControlResult::kStale);
  assert(ClipboardOffers(h) == 0);

  // A replacement session for the same call, peer and revision gets a new
  // generation; the old owner must not reach it.
  h.clock.now += 5000;
  h.Establish();
  const auto replacement = h.host->AuthorityStatus().host_generation;
  assert(replacement != generation);
  assert(SendOwned(h, generation) == LocalControlResult::kStale);
  assert(ClipboardOffers(h) == 0);
  assert(SendOwned(h, replacement) == LocalControlResult::kApplied);
  assert(ClipboardOffers(h) == 1);
}

void MouseUsesOwnedNegativeOriginAndRejectsLocalOutsideMove() {
  Harness h;
  h.current_surface = {
      {-1920, -200, 1920, 1080}, {-1920, -200, 3840, 1280}, L"LEFT-DISPLAY"};
  h.cursor_position = POINT{-1920, -200};
  const auto grant = h.Establish();
  h.Input(grant, 1, {WheelEvent{-120}});
  assert(h.os_calls.size() == 1);
  const auto& wheel = h.os_calls.front().mi;
  assert(wheel.dwFlags == (MOUSEEVENTF_MOVE | MOUSEEVENTF_ABSOLUTE |
                            MOUSEEVENTF_VIRTUALDESK | MOUSEEVENTF_WHEEL));
  assert(wheel.dx == 0 && wheel.dy == 0);
  assert(wheel.mouseData == static_cast<DWORD>(-120));
  h.cursor_position = POINT{0, -200};  // First pixel beyond the granted monitor.
  h.Input(grant, 2, {ButtonEvent{MouseButton::kLeft, true}});
  assert(h.os_calls.size() == 1);
  assert(h.host->AuthorityStatus().state == "inactive");
}

void LeaseRenewalPreservesTheActiveKeyAndButtonGrant() {
  Harness h;
  const auto grant = h.Establish();
  h.Input(grant, 1,
          {KeyEvent{'A', true}, ButtonEvent{MouseButton::kLeft, true}});
  assert(h.os_calls.size() == 2);
  assert(h.os_calls[0].type == INPUT_KEYBOARD &&
         (h.os_calls[0].ki.dwFlags & KEYEVENTF_KEYUP) == 0);
  assert(h.os_calls[1].type == INPUT_MOUSE &&
         h.os_calls[1].mi.dwFlags == (MOUSEEVENTF_LEFTDOWN | MOUSEEVENTF_MOVE |
                                       MOUSEEVENTF_ABSOLUTE | MOUSEEVENTF_VIRTUALDESK));
  const auto before = h.host->AuthorityStatus();
  assert(before.state == "active" && !before.blocked && before.release_complete);
  // The holds span two lease periods. A heartbeat must renew the existing
  // grant, not mistake legitimate held input for an unpaid release obligation.
  for (int renewal = 0; renewal < 6; ++renewal) {
    h.clock.now += 500;
    const auto status = h.host->SetProtectedSurface(
        h.channel_epoch, h.surface_revision, false);
    assert(status.state == "active" && !status.blocked && status.release_complete);
    assert(status.host_generation == before.host_generation &&
           status.revoked_through == before.revoked_through);
    assert(h.os_calls.size() == 2 && h.GrantCount() == 1);
  }
  // The original wire token and epoch still own both releases after renewal.
  h.Input(grant, 2,
          {KeyEvent{'A', false}, ButtonEvent{MouseButton::kLeft, false}});
  assert(h.os_calls.size() == 4);
  assert(h.os_calls[2].type == INPUT_KEYBOARD &&
         h.os_calls[2].ki.wVk == 'A' &&
         (h.os_calls[2].ki.dwFlags & KEYEVENTF_KEYUP) != 0);
  assert(h.os_calls[3].type == INPUT_MOUSE &&
         h.os_calls[3].mi.dwFlags == (MOUSEEVENTF_LEFTUP | MOUSEEVENTF_MOVE |
                                       MOUSEEVENTF_ABSOLUTE | MOUSEEVENTF_VIRTUALDESK));
  const auto after = h.host->AuthorityStatus();
  assert(after.state == "active" && !after.blocked && after.release_complete);
}

void CaptureGateBlocksEstablishedAuthorityWithoutDartStop() {
  Harness h;
  const auto grant = h.Establish();
  h.Input(grant, 1, {KeyEvent{'A', true}});
  const auto status = h.Block();
  assert(status.blocked && status.state == "inactive" &&
         status.release_complete);
  h.Input(grant, 2, {KeyEvent{'B', true}, TextEvent{"private"}});
  h.host->ReplayPendingEvents();
  assert(h.DownCalls() == 1);
  const auto count = h.GrantCount();
  h.envelope.call_id = "call-blocked";
  h.Request();
  assert(h.GrantCount() == count && !h.host->OwnsCall(h.envelope.call_id));
}

void FailedReleaseRemainsRevokingUntilConfirmed() {
  Harness h;
  const auto grant = h.Establish();
  h.Input(grant, 1, {KeyEvent{'A', true}});
  h.release_ok = false;
  assert(!h.host->Stop());
  auto status = h.host->AuthorityStatus();
  assert(status.state == "revoking" && !status.release_complete);
  h.Input(grant, 2, {KeyEvent{'B', true}});
  assert(h.DownCalls() == 1);
  h.envelope.call_id = "call-replacement";
  const auto pending = h.Request();
  assert(pending == 0 || h.Allow(pending) != LocalControlResult::kApplied);
  assert(h.GrantCount() == 1);
  h.release_ok = true;
  assert(h.host->Stop());
  status = h.host->AuthorityStatus();
  assert(status.state == "inactive" && status.release_complete);
  assert(h.DownCalls() == 1);
}

void DelayedReleaseDoesNotAcknowledgeCompletionEarly() {
  Harness h;
  const auto grant = h.Establish();
  h.Input(grant, 1, {KeyEvent{'A', true}});
  Barrier release;
  h.release_barrier = &release;
  auto stop = std::async(std::launch::async, [&] { return h.Block(); });
  release.Wait();
  assert(stop.wait_for(20ms) == std::future_status::timeout);
  auto late = std::async(std::launch::async, [&] {
    h.Input(grant, 2, {KeyEvent{'B', true}});
  });
  release.Release();
  const auto status = stop.get();
  late.get();
  assert(status.blocked && status.release_complete && status.state == "inactive");
  assert(h.DownCalls() == 1);
  h.release_barrier = nullptr;
}

void SequenceGapReleasesHeldInputAndRejectsLateMissingPacket() {
  Harness h;
  const auto grant = h.Establish();
  h.Input(grant, 1, {KeyEvent{'A', true}});
  h.Input(grant, 1, {KeyEvent{'B', true}});
  assert(h.DownCalls() == 1 && h.host->AuthorityStatus().state == "active");
  h.Input(grant, 3, {KeyEvent{'C', true}});
  const auto status = h.host->AuthorityStatus();
  assert(status.state == "inactive" && status.release_complete);
  assert(h.input_observer.calls() == 2 && IsRelease(h.os_calls.back()));
  h.Input(grant, 2, {KeyEvent{'D', true}});
  assert(h.DownCalls() == 1 && h.input_observer.calls() == 2);
}

void StopCancelsPendingManualAndSavedConsent() {
  Harness h;
  const auto pending = h.Request();
  assert(pending != 0);
  assert(h.host->Stop());
  assert(h.Allow(pending) == LocalControlResult::kStale);
  assert(h.GrantCount() == 0);

  Harness saved;
  assert(saved.grants.Save({kLocal, kAccount, kDevice}, 1000));
  saved.Establish();
  assert(saved.host->Stop());
  saved.clock.now += 4000;
  saved.envelope.call_id = "saved-second-call";
  assert(!saved.host->SetProtectedSurface(
      saved.channel_epoch, ++saved.surface_revision, false).blocked);
  const auto posted = saved.Request();
  assert(posted != 0);
  assert(saved.Allow(posted, true) == LocalControlResult::kUnavailable);
  saved.Block();
  assert(!saved.host->HandleWindowMessage(
      kAutoAllowMessage, static_cast<WPARAM>(posted & 0xffffffffULL),
      static_cast<LPARAM>(posted >> 32)));
  assert(saved.GrantCount() == 1 && saved.DownCalls() == 0);
  assert(saved.Allow(posted) == LocalControlResult::kStale);
}

void StopWhileActivationIsPendingCannotPublishLateGrant() {
  Harness h;
  const auto pending = h.Request();
  Barrier generation;
  h.crypto.generation_barrier = &generation;
  auto allow = std::async(std::launch::async, [&] { return h.Allow(pending); });
  generation.Wait();
  std::promise<void> stop_entered;
  auto stop = std::async(std::launch::async, [&] {
    stop_entered.set_value();
    return h.Block();
  });
  stop_entered.get_future().wait();
  assert(stop.wait_for(20ms) == std::future_status::timeout);
  generation.Release();
  assert(allow.get() != LocalControlResult::kApplied);
  const auto status = stop.get();
  assert(status.blocked && status.release_complete && status.state == "inactive");
  assert(h.GrantCount() == 0 && h.DownCalls() == 0);
  h.crypto.generation_barrier = nullptr;
}

void NativeStopDuringActivationCannotPublishLateGrant() {
  Harness h;
  const auto pending = h.Request();
  Barrier generation;
  h.crypto.generation_barrier = &generation;
  auto allow = std::async(std::launch::async, [&] { return h.Allow(pending); });
  generation.Wait();
  // No runtime epoch exists yet, but the displayed activation is cancelled.
  assert(!h.host->StopGeneration(pending));
  generation.Release();
  assert(allow.get() != LocalControlResult::kApplied);
  assert(h.GrantCount() == 0 && h.DownCalls() == 0);
  h.crypto.generation_barrier = nullptr;
}

void ChannelResetRejectsOldRevisionAndCannotReplayAuthority() {
  Harness h;
  const auto grant = h.Establish();
  h.Input(grant, 1, {KeyEvent{'A', true}});
  const auto old_epoch = h.channel_epoch;
  auto status = h.host->ResetAuthorityChannel(false);
  assert(status.blocked && status.release_complete && status.state == "inactive");
  status = h.host->SetProtectedSurface(old_epoch, 999, false);
  assert(status.blocked);
  status = h.host->ResetAuthorityChannel(true);
  assert(status.blocked && status.channel_epoch != old_epoch);
  h.channel_epoch = status.channel_epoch;
  status = h.host->SetProtectedSurface(old_epoch, 1000, false);
  assert(status.blocked);
  status = h.host->SetProtectedSurface(h.channel_epoch, 1, false);
  assert(!status.blocked && status.state == "inactive");
  h.Input(grant, 2, {KeyEvent{'B', true}});
  h.host->ReplayPendingEvents();
  assert(h.DownCalls() == 1 && h.GrantCount() == 1);
  status = h.host->SetProtectedSurface(h.channel_epoch, 2, true);
  assert(status.blocked);
  status = h.host->SetProtectedSurface(h.channel_epoch, 1, false);
  assert(status.blocked && status.surface_revision == 2);
}

void DisconnectAndReplacementRejectOldCallAndGrant() {
  Harness h;
  const auto old = h.Establish();
  h.Input(old, 1, {KeyEvent{'A', true}});
  h.host->OnCallEnded(h.envelope.call_id);
  assert(h.host->AuthorityStatus().state == "inactive");
  const auto old_envelope = h.envelope;
  h.envelope.call_id = "call-b";
  const auto current = h.Establish();
  h.host->OnCallEnded(old_envelope.call_id);
  h.host->OnSourceChanged(old_envelope.call_id, 100, false);
  h.Receive(Message{EndMessage{}}, old_envelope);
  h.Receive(Message{InputMessage{old.token, old.epoch, 2, old.source_revision,
                                 {KeyEvent{'B', true}}}}, old_envelope);
  assert(h.host->AuthorityStatus().state == "active");
  assert(h.DownCalls() == 1);
  h.Input(current, 1, {KeyEvent{'C', true}});
  assert(h.DownCalls() == 2);
}

void UnknownSafetyAndShutdownNeverPermitNewInput() {
  Harness unknown(false);
  assert(unknown.host->AuthorityStatus().blocked);
  assert(unknown.Request() == 0);
  assert(unknown.GrantCount() == 0);

  Harness h;
  const auto grant = h.Establish();
  h.desktop.observation = SafetyObservation::kUnknown;
  h.Input(grant, 1, {KeyEvent{'A', true}});
  assert(h.DownCalls() == 0);
  h.host->Shutdown();
  h.desktop.observation = SafetyObservation::kSafe;
  h.host->SetProtectedSurface(h.channel_epoch, 2, false);
  h.Input(grant, 2, {KeyEvent{'B', true}});
  h.host->ReplayPendingEvents();
  assert(h.DownCalls() == 0 && h.host->AuthorityStatus().blocked);
}

void FailedGrantPublicationAndAuthorityLossCannotActivate() {
  Harness transport;
  const auto request = transport.Request();
  transport.send_ok = false;
  assert(transport.Allow(request) == LocalControlResult::kUnavailable);
  assert(transport.host->AuthorityStatus().state == "inactive");
  assert(transport.DownCalls() == 0);
  for (const auto& [type, fields] : transport.events) {
    const auto state = fields.find("state");
    assert(type != "remoteControlState" || state == fields.end() ||
           state->second != "active");
  }

  Harness authority;
  const auto pending = authority.Request();
  authority.authority_ok = false;
  assert(authority.Allow(pending) == LocalControlResult::kUnavailable);
  assert(authority.GrantCount() == 0 && authority.DownCalls() == 0);
}

void TrustLossDuringConsentCannotPublishOrSave() {
  Harness h;
  const auto pending = h.Request();
  Barrier generation;
  h.crypto.generation_barrier = &generation;
  auto allow = std::async(std::launch::async,
                          [&] { return h.Allow(pending); });
  generation.Wait();
  h.authority_ok = false;
  generation.Release();
  assert(allow.get() != LocalControlResult::kApplied);
  assert(h.GrantCount() == 0 && h.DownCalls() == 0);
  assert(h.storage.bytes.empty());
  h.crypto.generation_barrier = nullptr;
}

void TrustLossDuringSaveCannotReviveSavedAuthority() {
  Harness h;
  const auto pending = h.Request();
  h.storage.after_write = [&] { h.authority_ok = false; };
  assert(h.Allow(pending, true) != LocalControlResult::kApplied);
  assert(h.GrantCount() == 0 && h.DownCalls() == 0);
  assert(h.storage.bytes.empty());
  assert(h.host->AuthorityStatus().state == "inactive");
}

void TrustLossAtSafetyRefreshRetiresInput() {
  Harness h;
  const auto grant = h.Establish();
  h.authority_ok = false;
  h.host->PollSafety();
  h.Input(grant, 1, {KeyEvent{'A', true}, KeyEvent{'B', true}});
  assert(h.DownCalls() == 0);
  assert(h.host->AuthorityStatus().state == "inactive");
}

void TrustRemovalCancelsPendingAndRejectsOldAllow() {
  Harness h;
  const auto pending = h.Request();
  assert(pending != 0);
  assert(h.host->OnTrustReduced(h.envelope.account_id, kLocal, kAccount));
  assert(h.Allow(pending, true) == LocalControlResult::kStale);
  assert(h.GrantCount() == 0 && h.storage.bytes.empty());
}

void TrustRemovalPreservesOtherPeerAndRetiresMatchingHeldInput() {
  Harness h;
  assert(h.grants.Save({kLocal, kAccount, kDevice}, 1000));
  const auto grant = h.Establish();
  h.Input(grant, 1, {KeyEvent{'A', true}});
  assert(h.host->OnTrustReduced(h.envelope.account_id, kLocal,
                               std::string(40, 'c')));
  assert(h.host->AuthorityStatus().state == "active");
  assert(h.DownCalls() == 1 && !h.storage.bytes.empty());
  assert(h.host->OnTrustReduced(h.envelope.account_id, kLocal, kAccount));
  const auto status = h.host->AuthorityStatus();
  assert(status.state == "inactive" && status.release_complete);
  assert(h.storage.bytes.empty());
  assert(h.input_observer.calls() == 2 && IsRelease(h.os_calls.back()));
  h.Input(grant, 2, {KeyEvent{'B', true}, TextEvent{"queued-after-retirement"}});
  assert(h.input_observer.calls() == 2);
}

void FailedTrustPurgeReportsFailureWithoutKeepingLiveAuthority() {
  Harness h;
  assert(h.grants.Save({kLocal, kAccount, kDevice}, 1000));
  const auto grant = h.Establish();
  h.Input(grant, 1, {KeyEvent{'A', true}});
  h.storage.fail_remove = true;
  assert(!h.host->OnTrustReduced(h.envelope.account_id, kLocal, kAccount));
  assert(h.host->AuthorityStatus().state == "inactive");
  assert(!h.storage.bytes.empty());
  assert(!h.grants.CanStore({kLocal, kAccount, kDevice}));
  h.Input(grant, 2, {KeyEvent{'B', true}});
  assert(h.DownCalls() == 1);
  h.storage.fail_remove = false;
  assert(h.host->OnTrustReduced(h.envelope.account_id, kLocal, kAccount));
  assert(h.storage.bytes.empty());
}

class CapturedResult final
    : public flutter::MethodResult<flutter::EncodableValue> {
 public:
  int calls = 0;
  std::optional<flutter::EncodableValue> value;
  std::string error;

 protected:
  void SuccessInternal(const flutter::EncodableValue* result) override {
    ++calls;
    assert(result);
    value = *result;
  }
  void ErrorInternal(const std::string& code, const std::string&,
                     const flutter::EncodableValue*) override {
    ++calls;
    error = code;
  }
  void NotImplementedInternal() override { assert(false); }
};

void ProductionChannelValidatesAndAcknowledgesTheNativeBoundary() {
  using flutter::EncodableMap;
  using flutter::EncodableValue;
  Harness h;
  const auto grant = h.Establish();
  h.Input(grant, 1, {KeyEvent{'A', true}});
  const auto dispatch = [&](const std::string& method, EncodableValue args,
                            CapturedResult& result) {
    flutter::MethodCall<EncodableValue> call(
        method, std::make_unique<EncodableValue>(std::move(args)));
    assert(HandleRemoteControlAuthorityCall(*h.host, call, result));
    assert(result.calls == 1);
  };
  const auto arguments = [&](EncodableValue epoch, EncodableValue revision,
                             EncodableValue blocked) {
    return EncodableValue(EncodableMap{
        {EncodableValue("channelEpoch"), std::move(epoch)},
        {EncodableValue("surfaceRevision"), std::move(revision)},
        {EncodableValue("blocked"), std::move(blocked)}});
  };
  CapturedResult query;
  dispatch("remoteControlHostAuthority", EncodableValue(), query);
  const auto& before = std::get<EncodableMap>(*query.value);
  assert(std::get<std::string>(before.at(EncodableValue("state"))) == "active");
  for (const auto* name : {"channelEpoch", "surfaceRevision", "hostGeneration",
                           "revokedThrough"}) {
    assert(std::holds_alternative<int64_t>(before.at(EncodableValue(name))));
  }
  assert(std::get<bool>(before.at(EncodableValue("releaseComplete"))));
  assert(!std::get<bool>(before.at(EncodableValue("blocked"))));

  CapturedResult malformed;
  dispatch("remoteControlSetProtectedSurface",
           arguments(EncodableValue(static_cast<int64_t>(h.channel_epoch)),
                     EncodableValue(int32_t{2}), EncodableValue("false")),
           malformed);
  assert(malformed.error == "invalid_control_authority");
  assert(h.host->AuthorityStatus().state == "active");
  CapturedResult negative;
  dispatch("remoteControlSetProtectedSurface",
           arguments(EncodableValue(int64_t{-1}), EncodableValue(int32_t{2}),
                     EncodableValue(true)), negative);
  assert(negative.error == "invalid_control_authority");

  CapturedResult blocked;
  dispatch("remoteControlSetProtectedSurface",
           arguments(EncodableValue(static_cast<int32_t>(h.channel_epoch)),
                     EncodableValue(static_cast<int64_t>(h.surface_revision + 1)),
                     EncodableValue(true)), blocked);
  const auto& after = std::get<EncodableMap>(*blocked.value);
  assert(std::get<bool>(after.at(EncodableValue("blocked"))));
  assert(std::get<bool>(after.at(EncodableValue("releaseComplete"))));
  assert(std::get<std::string>(after.at(EncodableValue("state"))) == "inactive");
  h.Input(grant, 2, {KeyEvent{'B', true}});
  assert(h.DownCalls() == 1);
  CapturedResult stale;
  dispatch("remoteControlSetProtectedSurface",
           arguments(EncodableValue(static_cast<int64_t>(h.channel_epoch)),
                     EncodableValue(int32_t{1}), EncodableValue(false)), stale);
  assert(std::get<bool>(std::get<EncodableMap>(*stale.value)
                           .at(EncodableValue("blocked"))));
  h.host->ResetAuthorityChannel(false);
  CapturedResult old_epoch;
  dispatch("remoteControlSetProtectedSurface",
           arguments(EncodableValue(static_cast<int64_t>(h.channel_epoch)),
                     EncodableValue(int64_t{999}), EncodableValue(false)),
           old_epoch);
  assert(std::get<bool>(std::get<EncodableMap>(*old_epoch.value)
                           .at(EncodableValue("blocked"))));
}

void LostChannelLeaseExpiresAtInputBoundaryWithoutAPoll() {
  Harness h;
  const auto old = h.Establish();
  h.Input(old, 1, {KeyEvent{'A', true}});
  h.clock.now += 1500;
  // No platform cancellation or timer poll occurs before this packet.
  h.Input(old, 2, {KeyEvent{'B', true}});
  assert(h.DownCalls() == 1);
  auto status = h.host->AuthorityStatus();
  assert(status.blocked && status.state == "inactive" && status.release_complete);
  status = h.host->SetProtectedSurface(
      h.channel_epoch, h.surface_revision, false);
  assert(status.blocked);
  h.surface_revision = status.surface_revision;
  status = h.host->SetProtectedSurface(
      h.channel_epoch, ++h.surface_revision, false);
  assert(!status.blocked && status.state == "inactive");
  h.Input(old, 3, {KeyEvent{'C', true}});
  assert(h.DownCalls() == 1);
  h.envelope.call_id = "after-channel-recovery";
  const auto current = h.Establish();
  h.Input(current, 1, {KeyEvent{'D', true}});
  assert(h.DownCalls() == 2);

  Harness text;
  const auto grant = text.Establish();
  text.on_input = [&](const INPUT& value) {
    if (value.type == INPUT_KEYBOARD &&
        (value.ki.dwFlags & KEYEVENTF_KEYUP) == 0)
      text.clock.now += 1500;
  };
  // One wire event expands into several OS operations. Only the first down
  // precedes expiry; its cleanup up remains allowed, and every later down is
  // refused, including the second event already queued in this same packet.
  text.Input(grant, 1, {TextEvent{"AB"}, KeyEvent{'C', true}});
  assert(text.DownCalls() == 1);
  assert(text.os_calls.size() == 2);
  assert((text.os_calls.back().ki.dwFlags & KEYEVENTF_KEYUP) != 0);
  text.Input(grant, 2, {KeyEvent{'D', true}});
  assert(text.DownCalls() == 1);
}

void NativeStopOnlyRetiresTheDisplayedGeneration() {
  Harness h;
  const auto first = h.Establish();
  const auto old_generation = h.host->AuthorityStatus().host_generation;
  h.Input(first, 1, {KeyEvent{'A', true}});
  assert(!h.host->StopGeneration(0));
  assert(!h.host->StopGeneration(old_generation + 1));
  assert(h.host->AuthorityStatus().state == "active");
  assert(h.host->StopGeneration(old_generation));
  assert(h.host->AuthorityStatus().release_complete);
  h.clock.now += 4000;  // Preserve the normal request deduplication interval.
  const auto replacement = h.Establish();
  assert(!h.host->StopGeneration(old_generation));
  assert(h.host->AuthorityStatus().state == "active");
  h.Input(replacement, 1, {KeyEvent{'B', true}});
  assert(h.host->StopGeneration(h.host->AuthorityStatus().host_generation));
  assert(h.host->AuthorityStatus().state == "inactive");
  assert(h.host->AuthorityStatus().release_complete);
}

void MouseReleaseFailureRetainsAuthorityCleanup() {
  Harness h;
  const auto grant = h.Establish();
  h.Input(grant, 1, {ButtonEvent{MouseButton::kLeft, true}});
  assert(h.input_observer.calls() == 1);
  h.release_ok = false;
  const auto failed = h.Block();
  assert(failed.blocked && failed.state == "revoking" &&
         !failed.release_complete);
  assert(h.input_observer.calls() == 2);
  assert(h.os_calls.back().mi.dwFlags == MOUSEEVENTF_LEFTUP);
  h.Input(grant, 2, {ButtonEvent{MouseButton::kRight, true}});
  assert(h.input_observer.calls() == 3);  // Only the owed left-up is retried.
  assert(h.os_calls.back().mi.dwFlags == MOUSEEVENTF_LEFTUP);
  h.release_ok = true;
  assert(h.host->Stop());
  assert(h.input_observer.calls() == 4);
  assert(h.os_calls.back().mi.dwFlags == MOUSEEVENTF_LEFTUP);
  h.Input(grant, 3, {ButtonEvent{MouseButton::kRight, true}});
  assert(h.host->Stop());
  assert(h.input_observer.calls() == 4);
}

void MouseReleaseDelayPreventsEarlyAcknowledgement() {
  Harness h;
  const auto grant = h.Establish();
  h.Input(grant, 1, {ButtonEvent{MouseButton::kX1, true}});
  Barrier release;
  h.release_barrier = &release;
  auto block = std::async(std::launch::async, [&] { return h.Block(); });
  release.Wait();
  assert(block.wait_for(0ms) == std::future_status::timeout);
  assert(h.input_observer.calls() == 2);
  auto late = std::async(std::launch::async, [&] {
    h.Input(grant, 2, {ButtonEvent{MouseButton::kRight, true}});
  });
  release.Release();
  const auto status = block.get();
  late.get();
  h.release_barrier = nullptr;
  assert(status.blocked && status.state == "inactive" && status.release_complete);
  assert(h.input_observer.calls() == 2);
  assert(h.os_calls.back().mi.dwFlags == MOUSEEVENTF_XUP &&
         h.os_calls.back().mi.mouseData == XBUTTON1);
  h.Input(grant, 3, {ButtonEvent{MouseButton::kLeft, true}});
  assert(h.input_observer.calls() == 2);
}

void UnicodeReleaseFailureRetainsHostCleanup() {
  Harness h;
  const auto grant = h.Establish();
  h.release_ok = false;
  h.Input(grant, 1, {TextEvent{"ab"}, KeyEvent{'C', true}});
  const auto status = h.host->AuthorityStatus();
  assert(status.state == "revoking" && !status.release_complete);
  assert(h.DownCalls() == 1);
  // Down, failed up, compensation, then policy and runtime cleanup attempts.
  assert(h.input_observer.calls() == 5);
  for (const auto& value : h.os_calls) {
    assert(value.type == INPUT_KEYBOARD && value.ki.wScan == 'a' &&
           (value.ki.dwFlags & KEYEVENTF_UNICODE) != 0);
  }
  h.Input(grant, 2, {TextEvent{"z"}});
  assert(h.DownCalls() == 1);
  h.release_ok = true;
  assert(h.host->Stop());
  const auto completed = h.input_observer.calls();
  assert(h.os_calls.back().ki.wScan == 'a' && IsRelease(h.os_calls.back()));
  h.Input(grant, 3, {TextEvent{"z"}});
  assert(h.host->Stop());
  assert(h.input_observer.calls() == completed);
}

void BlockInterruptsImportedInputAndItsQueuedTail() {
  Harness h;
  const auto grant = h.Establish();
  Barrier input;
  h.input_barrier = &input;
  auto draining = std::async(std::launch::async, [&] {
    h.Input(grant, 1, {KeyEvent{'A', true}, KeyEvent{'B', true},
                       ButtonEvent{MouseButton::kLeft, true}, TextEvent{"tail"}});
  });
  input.Wait();
  assert(h.input_observer.calls() == 1);
  auto block = std::async(std::launch::async, [&] { return h.Block(); });
  h.WaitForBlockAdmission();
  assert(block.wait_for(0ms) == std::future_status::timeout);
  auto late = std::async(std::launch::async, [&] {
    h.Input(grant, 2, {KeyEvent{'C', true}});
  });
  input.Release();
  draining.get();
  const auto status = block.get();
  late.get();
  h.input_barrier = nullptr;
  assert(status.blocked && status.state == "inactive" && status.release_complete);
  assert(h.input_observer.calls() == 2 && h.DownCalls() == 1);
  assert(h.os_calls[0].ki.wVk == 'A' && !IsRelease(h.os_calls[0]));
  assert(h.os_calls[1].ki.wVk == 'A' && IsRelease(h.os_calls[1]));
  h.Input(grant, 3, {KeyEvent{'D', true}, TextEvent{"after"}});
  h.host->PollSafety();
  assert(h.input_observer.calls() == 2);
}

void LeaseExpiryReleasesHeldKeyAndButtonWithoutAPoll() {
  Harness h;
  const auto grant = h.Establish();
  h.Input(grant, 1, {KeyEvent{'A', true}, ButtonEvent{MouseButton::kLeft, true}});
  assert(h.input_observer.calls() == 2);
  h.clock.now += 1500;
  h.Input(grant, 2, {KeyEvent{'B', true}, ButtonEvent{MouseButton::kRight, true}});
  const auto status = h.host->AuthorityStatus();
  assert(status.blocked && status.state == "inactive" && status.release_complete);
  assert(h.input_observer.calls() == 4 && h.DownCalls() == 1);
  assert(IsRelease(h.os_calls[2]) && IsRelease(h.os_calls[3]));
  h.Input(grant, 3, {TextEvent{"expired"}});
  assert(h.input_observer.calls() == 4);
}

void UnknownProbeStopsInput(FakeSafety Harness::* probe) {
  Harness h;
  const auto grant = h.Establish();
  h.Input(grant, 1, {KeyEvent{'A', true}, ButtonEvent{MouseButton::kLeft, true}});
  (h.*probe).observation = SafetyObservation::kUnknown;
  h.Input(grant, 2, {KeyEvent{'B', true}, TextEvent{"unknown"}});
  assert(h.DownCalls() == 1);
  const bool unknown_desktop = probe == &Harness::desktop;
  assert(h.input_observer.calls() == (unknown_desktop ? 2 : 4));
  const auto blocked = h.Block();
  assert(blocked.blocked && blocked.release_complete == !unknown_desktop);
  assert(blocked.state == (unknown_desktop ? "revoking" : "inactive"));
  (h.*probe).observation = SafetyObservation::kSafe;
  assert(h.host->Stop());
  assert(h.input_observer.calls() == 4);
  h.Input(grant, 3, {KeyEvent{'C', true}});
  assert(h.input_observer.calls() == 4);
}

void LifecycleRevocationReleasesAndRejectsLateInput(int trigger) {
  Harness h;
  const auto grant = h.Establish();
  h.Input(grant, 1, {KeyEvent{'A', true}, ButtonEvent{MouseButton::kLeft, true}});
  if (trigger == 0) h.host->OnSourceChanged(h.envelope.call_id, 8, true);
  if (trigger == 1) h.host->OnCallEnded(h.envelope.call_id);
  if (trigger == 2) h.host->Shutdown();
  const auto status = h.host->AuthorityStatus();
  assert(status.state == "inactive" && status.release_complete);
  assert(h.input_observer.calls() == 4);
  h.Input(grant, 2, {KeyEvent{'B', true}, TextEvent{"late"}});
  assert(h.input_observer.calls() == 4);
}

std::string selected_case;
std::size_t cases_run = 0;

void RunCase(const char* name, void (*test_case)()) {
  if (!selected_case.empty() && selected_case != name) return;
  assert(!test::ScopedSendInputObserver::active());
  const auto before = import_calls.load();
  test_case();
  ++cases_run;
  assert(!test::ScopedSendInputObserver::active());
  std::printf("PASS %s: %llu SendInput import calls\n", name,
              static_cast<unsigned long long>(import_calls.load() - before));
}

}  // namespace

int main(int argc, char** argv) {
  if (argc > 2) return 2;
  if (argc > 1) selected_case = argv[1];
#define RUN_CASE(name) RunCase(#name, name)
  RUN_CASE(NormalStopAcknowledgesReleaseAndRejectsLateInput);
  RUN_CASE(ChangedTopologyRejectsMouseBeforeSafetyPoll);
  RUN_CASE(MouseChecksExactSurfaceBetweenOperations);
  RUN_CASE(MouseSurfaceCheckCannotDeadlockClipboardAdmission);
  RUN_CASE(ClipboardSendRequiresTheCapturedHostSession);
  RUN_CASE(ClipboardSendAfterTheSessionEndedIsStale);
  RUN_CASE(MouseUsesOwnedNegativeOriginAndRejectsLocalOutsideMove);
  RUN_CASE(LeaseRenewalPreservesTheActiveKeyAndButtonGrant);
  RUN_CASE(CaptureGateBlocksEstablishedAuthorityWithoutDartStop);
  RUN_CASE(FailedReleaseRemainsRevokingUntilConfirmed);
  RUN_CASE(DelayedReleaseDoesNotAcknowledgeCompletionEarly);
  RUN_CASE(StopCancelsPendingManualAndSavedConsent);
  RUN_CASE(SequenceGapReleasesHeldInputAndRejectsLateMissingPacket);
  RUN_CASE(StopWhileActivationIsPendingCannotPublishLateGrant);
  RUN_CASE(ChannelResetRejectsOldRevisionAndCannotReplayAuthority);
  RUN_CASE(DisconnectAndReplacementRejectOldCallAndGrant);
  RUN_CASE(UnknownSafetyAndShutdownNeverPermitNewInput);
  RUN_CASE(FailedGrantPublicationAndAuthorityLossCannotActivate);
  RUN_CASE(TrustLossDuringConsentCannotPublishOrSave);
  RUN_CASE(TrustLossDuringSaveCannotReviveSavedAuthority);
  RUN_CASE(TrustLossAtSafetyRefreshRetiresInput);
  RUN_CASE(TrustRemovalCancelsPendingAndRejectsOldAllow);
  RUN_CASE(TrustRemovalPreservesOtherPeerAndRetiresMatchingHeldInput);
  RUN_CASE(FailedTrustPurgeReportsFailureWithoutKeepingLiveAuthority);
  RUN_CASE(ProductionChannelValidatesAndAcknowledgesTheNativeBoundary);
  RUN_CASE(LostChannelLeaseExpiresAtInputBoundaryWithoutAPoll);
  RUN_CASE(MouseReleaseFailureRetainsAuthorityCleanup);
  RUN_CASE(NativeStopOnlyRetiresTheDisplayedGeneration);
  RUN_CASE(NativeStopDuringActivationCannotPublishLateGrant);
  RUN_CASE(MouseReleaseDelayPreventsEarlyAcknowledgement);
  RUN_CASE(UnicodeReleaseFailureRetainsHostCleanup);
  RUN_CASE(BlockInterruptsImportedInputAndItsQueuedTail);
  RUN_CASE(LeaseExpiryReleasesHeldKeyAndButtonWithoutAPoll);
  RunCase("UnknownPrivilegeStopsInput", [] {
    UnknownProbeStopsInput(&Harness::privilege);
  });
  RunCase("UnknownDesktopStopsInput", [] {
    UnknownProbeStopsInput(&Harness::desktop);
  });
  RunCase("UnknownBannerStopsInput", [] {
    UnknownProbeStopsInput(&Harness::banner);
  });
  RunCase("SourceChangeReleasesAndRejectsLateInput", [] {
    LifecycleRevocationReleasesAndRejectsLateInput(0);
  });
  RunCase("CallEndReleasesAndRejectsLateInput", [] {
    LifecycleRevocationReleasesAndRejectsLateInput(1);
  });
  RunCase("ShutdownReleasesAndRejectsLateInput", [] {
    LifecycleRevocationReleasesAndRejectsLateInput(2);
  });
#undef RUN_CASE
  if (cases_run == 0) {
    std::fprintf(stderr, "Unknown test case: %s\n", selected_case.c_str());
    return 2;
  }
  std::printf("remote_control_host_test: %zu production-host scenarios passed\n",
              cases_run);
  return 0;
}
