#ifdef NDEBUG
#undef NDEBUG
#endif

#include "remote_control_runtime.h"

#include <algorithm>
#include <atomic>
#include <cassert>
#include <chrono>
#include <condition_variable>
#include <mutex>
#include <set>
#include <string>
#include <thread>
#include <vector>

using namespace sybl::remote;

namespace {

constexpr auto kAccount = "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa";
constexpr auto kDevice =
    "1111111111111111111111111111111111111111111111111111111111111111";
constexpr auto kHash =
    "0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef";

SessionBinding Binding() {
  return {"call-a", kAccount, kDevice, 7};
}

DesktopRect Source() {
  return {-1920, 0, 1920, 1080};
}

DesktopRect VirtualDesktop() {
  return {-1920, 0, 3840, 1080};
}

class FakeInput final : public InputAdapter {
 public:
  bool Apply(const InputEvent& event,
             const DesktopRect&,
             const DesktopRect&) override {
    if (block_apply) {
      std::unique_lock<std::mutex> lock(apply_mutex);
      apply_entered = true;
      apply_changed.notify_all();
      apply_changed.wait(lock, [this] { return allow_apply; });
    }
    ++apply_calls;
    applied.push_back(event);
    if (on_apply) on_apply();
    return apply_ok;
  }
  bool ReleaseKey(std::uint16_t key) override {
    released_keys.push_back(key);
    return release_ok;
  }
  bool ReleaseButton(MouseButton button) override {
    released_buttons.push_back(button);
    return release_ok;
  }

  bool apply_ok = true;
  std::function<void()> on_apply;
  bool release_ok = true;
  int apply_calls = 0;
  std::vector<InputEvent> applied;
  std::vector<std::uint16_t> released_keys;
  std::vector<MouseButton> released_buttons;
  bool block_apply = false;
  bool apply_entered = false;
  bool allow_apply = false;
  std::mutex apply_mutex;
  std::condition_variable apply_changed;
};

class FakeSecrets final : public SecretSource {
 public:
  std::optional<std::string> GenerateHex(std::size_t bytes) override {
    assert(bytes == 16);
    ++calls;
    return calls == 1 ? "00112233445566778899aabbccddeeff"
                      : "ffeeddccbbaa99887766554433221100";
  }
  int calls = 0;
};

class FakeHashes : public HashProvider {
 public:
  std::optional<std::string> Sha256Hex(std::string_view value) override {
    last = std::string(value);
    return kHash;
  }
  std::string last;
};

class FakeSafety final : public InputDesktopProbe,
                         public BannerVisibilityProbe,
                         public ProcessPrivilegeProbe {
 public:
  SafetyObservation Observe() override {
    ++calls;
    if (unsafe_on_call > 0 && calls >= unsafe_on_call)
      return SafetyObservation::kUnsafe;
    return observation;
  }
  SafetyObservation observation = SafetyObservation::kSafe;
  int calls = 0;
  int unsafe_on_call = 0;
};

class FakeHotkey final : public KillHotkeyRegistrar {
 public:
  bool Register(HWND owner, int id, UINT modifiers, UINT key) override {
    assert(owner);
    attempts.push_back(HotkeyBinding{id, modifiers, key});
    // Model the OS: an id the system still holds cannot be re-registered
    // (ERROR_HOTKEY_ALREADY_REGISTERED). Without this the fake would happily
    // hand back an id it never released, hiding a real leak.
    if (live.count(id) != 0) return false;
    if (results.empty()) return false;
    const bool result = results.front();
    results.erase(results.begin());
    if (result) live.insert(id);
    return result;
  }
  bool Unregister(HWND owner, int id) override {
    assert(owner);
    if (!unregister_ok) return false;
    unregistered.push_back(id);
    live.erase(id);
    return true;
  }
  std::vector<bool> results{true};
  bool unregister_ok = true;
  std::set<int> live;  // ids the "OS" currently holds
  std::vector<HotkeyBinding> attempts;
  std::vector<int> unregistered;
};

class FakeRaw final : public RawInputMonitor {
 public:
  bool Register(HWND owner) override {
    ++register_calls;
    registered_owner = owner;
    return register_ok;
  }
  void Unregister() override {
    ++unregister_calls;
    registered_owner = nullptr;
  }
  RawInputOrigin Classify(LPARAM value) override {
    if (value == 1) return RawInputOrigin::kPhysical;
    if (value == 2) return RawInputOrigin::kInjected;
    return RawInputOrigin::kUnknown;
  }
  bool register_ok = true;
  int register_calls = 0;
  int unregister_calls = 0;
  HWND registered_owner = nullptr;
};

class FakeClock final : public MonotonicClock {
 public:
  std::uint64_t NowMs() override { return now.load(); }
  std::atomic<std::uint64_t> now{1000};
};

struct Harness {
  FakeInput input;
  FakeSecrets secrets;
  FakeHashes hashes;
  FakeSafety process_privilege;
  FakeSafety desktop;
  FakeSafety banner;
  FakeHotkey hotkey;
  FakeRaw raw;
  FakeClock clock;
  RuntimeConfig config;
  std::vector<RuntimeEvent> events;
  RemoteControlRuntime runtime;

  explicit Harness(bool surface_known = true)
      : runtime(input, secrets, hashes, process_privilege, desktop, banner,
                hotkey, raw, clock, config) {
    if (surface_known)
      assert(runtime.SetInputBlocked(false, UINT64_MAX, runtime.block_generation()));
    runtime.SetEventCallback([this](const RuntimeEvent& event) {
      events.push_back(event);
    });
  }

  std::optional<ActiveGrant> Activate(
      Capabilities capabilities =
          static_cast<Capabilities>(CapabilityBit(Capability::kMouse) |
                                    CapabilityBit(Capability::kKeyboard) |
                                    CapabilityBit(Capability::kClipboard))) {
    return runtime.Activate(reinterpret_cast<HWND>(1), Binding(), Source(),
                            VirtualDesktop(), capabilities);
  }
};

InputMessage Input(const ActiveGrant& grant,
                   std::uint64_t sequence,
                   std::vector<InputEvent> events) {
  return {grant.token, grant.epoch, sequence, grant.binding.source_revision,
          std::move(events)};
}

void ProcessPrivilegeIsClassifiedAndEnforcedFailClosed() {
  assert(ClassifyProcessPrivilege(SECURITY_MANDATORY_MEDIUM_RID, false) ==
         SafetyObservation::kSafe);
  assert(ClassifyProcessPrivilege(SECURITY_MANDATORY_MEDIUM_RID + 0x100,
                                  false) == SafetyObservation::kSafe);
  assert(ClassifyProcessPrivilege(SECURITY_MANDATORY_LOW_RID, false) ==
         SafetyObservation::kUnsafe);
  assert(ClassifyProcessPrivilege(SECURITY_MANDATORY_HIGH_RID, false) ==
         SafetyObservation::kUnsafe);
  assert(ClassifyProcessPrivilege(SECURITY_MANDATORY_SYSTEM_RID, false) ==
         SafetyObservation::kUnsafe);
  assert(ClassifyProcessPrivilege(SECURITY_MANDATORY_MEDIUM_RID, true) ==
         SafetyObservation::kUnsafe);

  Harness unknown;
  unknown.process_privilege.observation = SafetyObservation::kUnknown;
  assert(!unknown.Activate());
  assert(unknown.runtime.state() == RuntimeState::kIdle);
  assert(unknown.raw.register_calls == 0);

  Harness unsafe;
  unsafe.process_privilege.observation = SafetyObservation::kUnsafe;
  assert(!unsafe.Activate());
  assert(unsafe.runtime.state() == RuntimeState::kIdle);
  assert(unsafe.raw.register_calls == 0);

  Harness changed;
  const auto grant = changed.Activate();
  assert(grant);
  assert(changed.runtime.QueueInput(
             Binding(), Input(*grant, 1, {MoveEvent{0.5, 0.5}})) ==
         RuntimeQueueDecision::kQueued);
  // Activate=1, Queue Poll=2, Drain Poll=3, per-event guard=4. This proves a
  // privilege change between the batch-level poll and SendInput still wins.
  changed.process_privilege.unsafe_on_call = 4;
  assert(changed.runtime.DrainOne() ==
         DrainDecision::kAdapterFailureRevoke);
  assert(changed.input.apply_calls == 0);
  assert(changed.runtime.state() == RuntimeState::kIdle);
  assert(changed.events.back().type == RuntimeEventType::kRevoked);
  assert(changed.events.back().reason ==
         RuntimeReason::kProcessPrivilegeUnsafe);

  Harness poll;
  assert(poll.Activate());
  poll.process_privilege.observation = SafetyObservation::kUnknown;
  poll.runtime.PollSafety();
  assert(poll.runtime.state() == RuntimeState::kIdle);
  assert(poll.events.back().reason ==
         RuntimeReason::kProcessPrivilegeUnknown);
}

void ActivationIsDefaultDenyAndFallbackIsVisible() {
  Harness harness;
  harness.desktop.observation = SafetyObservation::kUnknown;
  assert(!harness.Activate());
  assert(harness.runtime.state() == RuntimeState::kIdle);
  assert(harness.raw.register_calls == 0);

  harness.desktop.observation = SafetyObservation::kSafe;
  harness.banner.observation = SafetyObservation::kUnsafe;
  assert(!harness.Activate());
  assert(harness.raw.register_calls == 0);

  harness.banner.observation = SafetyObservation::kSafe;
  harness.raw.register_ok = false;
  assert(!harness.Activate());
  assert(harness.runtime.state() == RuntimeState::kIdle);

  harness.raw.register_ok = true;
  harness.hotkey.results = {false, true};
  bool callback_reentered = false;
  harness.runtime.SetEventCallback([&](const RuntimeEvent& event) {
    harness.events.push_back(event);
    if (event.type == RuntimeEventType::kActivated) {
      callback_reentered = harness.runtime.state() == RuntimeState::kActive;
    }
  });
  const auto grant = harness.Activate();
  assert(grant);
  assert(callback_reentered);  // proves callback is outside the runtime lock
  assert(harness.hotkey.attempts.size() == 2);
  assert(harness.runtime.hotkey_available());
  const auto hotkey_event = harness.events.back();
  assert(hotkey_event.type == RuntimeEventType::kHotkeyRegistered);
  assert(hotkey_event.hotkey_id == harness.config.fallback_hotkey.id);
  assert(harness.runtime.Stop());

  Harness unavailable;
  unavailable.hotkey.results = {false, false};
  assert(unavailable.Activate());
  assert(unavailable.runtime.state() == RuntimeState::kActive);
  assert(!unavailable.runtime.hotkey_available());
  assert(unavailable.raw.unregister_calls == 0);
  assert(unavailable.events.back().type ==
         RuntimeEventType::kHotkeyUnavailable);
  assert(unavailable.events.back().state == RuntimeState::kActive);
  assert(unavailable.runtime.Stop());
  assert(unavailable.raw.unregister_calls == 1);
}

void InputIsCheckedBeforeQueueAndEveryApply() {
  Harness harness;
  const auto grant = harness.Activate();
  assert(grant);
  const auto message = Input(*grant, 1, {KeyEvent{65, true}});
  assert(harness.runtime.QueueInput(Binding(), message) ==
         RuntimeQueueDecision::kQueued);
  assert(harness.runtime.DrainOne() == DrainDecision::kApplied);
  assert(harness.input.apply_calls == 1);
  assert(harness.input.released_keys.empty());

  harness.banner.observation = SafetyObservation::kUnsafe;
  harness.runtime.PollSafety();
  assert(harness.runtime.state() == RuntimeState::kSuspended);
  assert(harness.runtime.suspend_reason() == RuntimeReason::kBannerHidden);
  assert(harness.input.released_keys ==
         std::vector<std::uint16_t>{65});
  assert(harness.runtime.QueueInput(
             Binding(), Input(*grant, 2, {MoveEvent{0, 0}})) ==
         RuntimeQueueDecision::kSuspended);

  harness.banner.observation = SafetyObservation::kSafe;
  harness.runtime.PollSafety();
  assert(harness.runtime.state() == RuntimeState::kActive);

  Harness edge;
  const auto edge_grant = edge.Activate();
  assert(edge_grant);
  assert(edge.runtime.QueueInput(
             Binding(), Input(*edge_grant, 1, {MoveEvent{0, 0}})) ==
         RuntimeQueueDecision::kQueued);
  // Activate=1, Queue Poll=2, Drain Poll=3, per-event guard=4.
  edge.banner.unsafe_on_call = 4;
  assert(edge.runtime.DrainOne() == DrainDecision::kAdapterFailureRevoke);
  assert(edge.input.apply_calls == 0);
  assert(edge.runtime.state() == RuntimeState::kIdle);
  assert(edge.events.back().type == RuntimeEventType::kRevoked);
  assert(edge.events.back().reason == RuntimeReason::kBannerHidden);
}

void PhysicalInputSuppressesAndReleasesRemoteHolds() {
  Harness harness;
  const auto grant = harness.Activate();
  assert(grant);
  assert(harness.runtime.QueueInput(
             Binding(), Input(*grant, 1, {KeyEvent{65, true}})) ==
         RuntimeQueueDecision::kQueued);
  assert(harness.runtime.DrainOne() == DrainDecision::kApplied);
  assert(harness.input.released_keys.empty());

  assert(harness.runtime.HandleRawInput(2) == RawInputOrigin::kInjected);
  assert(harness.runtime.state() == RuntimeState::kActive);

  assert(harness.runtime.HandleRawInput(1) == RawInputOrigin::kPhysical);
  assert(harness.runtime.state() == RuntimeState::kSuspended);
  assert(harness.input.released_keys ==
         std::vector<std::uint16_t>{65});
  assert(harness.runtime.QueueInput(
             Binding(), Input(*grant, 2, {MoveEvent{0, 0}})) ==
         RuntimeQueueDecision::kSuppressedByPhysicalHost);
  assert(harness.events.back().type ==
         RuntimeEventType::kPhysicalTakeover);

  harness.clock.now = 1599;
  harness.runtime.PollSafety();
  assert(harness.runtime.state() == RuntimeState::kSuspended);
  harness.clock.now = 1600;
  harness.runtime.PollSafety();
  assert(harness.runtime.state() == RuntimeState::kActive);

  assert(harness.runtime.HandleRawInput(99) == RawInputOrigin::kUnknown);
  assert(harness.runtime.state() == RuntimeState::kSuspended);
}

void CoControlKeepsBothLocalAndRemoteInputLive() {
  Harness harness;
  const auto grant = harness.Activate();
  assert(grant);
  assert(!harness.runtime.co_control());
  assert(harness.runtime.SetCoControl(true));
  assert(harness.runtime.co_control());
  assert(harness.runtime.HandleRawInput(1) == RawInputOrigin::kPhysical);
  assert(harness.runtime.state() == RuntimeState::kActive);
  assert(harness.runtime.host_priority_until_ms() == 1600);
  assert(harness.runtime.QueueInput(
             Binding(), Input(*grant, 1, {MoveEvent{0, 0}})) ==
         RuntimeQueueDecision::kQueued);
  assert(harness.runtime.DrainOne() == DrainDecision::kApplied);
  assert(harness.input.apply_calls == 1);
  // The physical-input observation is remembered. Switching back to
  // host-priority inside the 600 ms window immediately suppresses remote
  // input, proving the two locally-owned modes differ behaviorally.
  assert(harness.runtime.SetCoControl(false));
  assert(harness.runtime.state() == RuntimeState::kSuspended);
  assert(harness.runtime.QueueInput(
             Binding(), Input(*grant, 2, {MoveEvent{1, 1}})) ==
         RuntimeQueueDecision::kSuppressedByPhysicalHost);
  harness.clock.now = 1600;
  harness.runtime.PollSafety();
  assert(harness.runtime.state() == RuntimeState::kActive);
  assert(!harness.runtime.co_control());
  assert(harness.runtime.Stop());
  assert(!harness.runtime.co_control());
  assert(!harness.runtime.SetCoControl(true));
}

void StaleBindingCannotMutateAReplacementSession() {
  Harness harness;
  const auto first = harness.Activate();
  assert(first);
  const auto first_binding = first->binding;
  auto stale = first_binding;
  ++stale.source_revision;

  assert(!harness.runtime.SetCoControlIfBinding(stale, true));
  assert(!harness.runtime.co_control());
  assert(!harness.runtime.StopIfBinding(
      stale, first->epoch, RuntimeReason::kSourceChanged));
  assert(harness.runtime.state() == RuntimeState::kActive);

  assert(harness.runtime.SetCoControlIfBinding(first_binding, true));
  assert(harness.runtime.co_control());
  assert(harness.runtime.StopIfBinding(
      first_binding, first->epoch, RuntimeReason::kLocalStop));

  const auto replacement = harness.runtime.Activate(
      reinterpret_cast<HWND>(1), stale, Source(), VirtualDesktop(),
      static_cast<Capabilities>(
          CapabilityBit(Capability::kMouse) |
          CapabilityBit(Capability::kKeyboard)));
  assert(replacement);
  assert(!harness.runtime.SetCoControlIfBinding(first_binding, true));
  assert(!harness.runtime.co_control());
  assert(!harness.runtime.StopIfBinding(
      first_binding, first->epoch, RuntimeReason::kCallEnded));
  assert(harness.runtime.grant().binding == stale);
  assert(harness.runtime.StopIfBinding(
      stale, replacement->epoch, RuntimeReason::kLocalStop));
}

void ScopedStopPreemptsTheMatchingInFlightBatch() {
  Harness harness;
  const auto grant = harness.Activate();
  assert(grant);
  harness.input.block_apply = true;
  assert(harness.runtime.QueueInput(
             Binding(),
             Input(*grant, 1,
                   {MoveEvent{0, 0}, MoveEvent{0.5, 0.5},
                    MoveEvent{1, 1}})) ==
         RuntimeQueueDecision::kQueued);

  DrainDecision drained = DrainDecision::kEmpty;
  std::thread drain([&] { drained = harness.runtime.DrainOne(); });
  {
    std::unique_lock<std::mutex> lock(harness.input.apply_mutex);
    harness.input.apply_changed.wait(
        lock, [&] { return harness.input.apply_entered; });
  }

  std::atomic<bool> stop_started{false};
  bool stopped = false;
  std::thread stop([&] {
    stop_started = true;
    stopped = harness.runtime.StopIfBinding(
        Binding(), grant->epoch, RuntimeReason::kSourceChanged);
  });
  while (!stop_started.load()) std::this_thread::yield();
  // StopIfBinding raises the scoped interrupt before contending for the
  // runtime mutex held by DrainOne.
  std::this_thread::sleep_for(std::chrono::milliseconds(10));
  {
    std::lock_guard<std::mutex> lock(harness.input.apply_mutex);
    harness.input.allow_apply = true;
  }
  harness.input.apply_changed.notify_all();
  drain.join();
  stop.join();

  assert(stopped);
  assert(drained == DrainDecision::kApplied);
  assert(harness.input.apply_calls == 1);
  assert(harness.runtime.state() == RuntimeState::kIdle);
}

void ActivationCanStartInLocallyApprovedCoControl() {
  Harness harness;
  const auto grant = harness.runtime.Activate(
      reinterpret_cast<HWND>(1), Binding(), Source(), VirtualDesktop(),
      static_cast<Capabilities>(CapabilityBit(Capability::kMouse) |
                                CapabilityBit(Capability::kKeyboard)),
      true);
  assert(grant);
  assert(harness.runtime.co_control());
  assert(harness.runtime.HandleRawInput(1) == RawInputOrigin::kPhysical);
  assert(harness.runtime.state() == RuntimeState::kActive);
  assert(harness.runtime.QueueInput(
             Binding(), Input(*grant, 1, {MoveEvent{0, 0}})) ==
         RuntimeQueueDecision::kQueued);
  assert(harness.runtime.DrainOne() == DrainDecision::kApplied);
}

void HotkeyAndQueuePressureRevokeNativeAuthority() {
  Harness hotkey;
  assert(hotkey.Activate());
  assert(!hotkey.runtime.HandleWindowMessage(WM_HOTKEY, 999, 0));
  assert(hotkey.runtime.HandleWindowMessage(
      WM_HOTKEY, hotkey.config.preferred_hotkey.id, 0));
  assert(hotkey.runtime.state() == RuntimeState::kIdle);
  assert(hotkey.events.back().reason == RuntimeReason::kHotkey);
  assert(hotkey.raw.unregister_calls == 1);

  Harness pressure;
  pressure.config.policy.max_queued_batches = 1;
  // RuntimeConfig is copied at construction, so use a dedicated construction.
  FakeInput input;
  FakeSecrets secrets;
  FakeHashes hashes;
  FakeSafety process_privilege;
  FakeSafety desktop;
  FakeSafety banner;
  FakeHotkey registrar;
  FakeRaw raw;
  FakeClock clock;
  RuntimeConfig config;
  config.policy.max_queued_batches = 1;
  RemoteControlRuntime runtime(input, secrets, hashes, process_privilege,
                               desktop, banner, registrar, raw, clock, config);
  assert(runtime.SetInputBlocked(false, UINT64_MAX, runtime.block_generation()));
  const auto grant = runtime.Activate(reinterpret_cast<HWND>(1), Binding(),
                                      Source(), VirtualDesktop(),
                                      CapabilityBit(Capability::kMouse));
  assert(grant);
  assert(runtime.QueueInput(
             Binding(), Input(*grant, 1, {MoveEvent{0, 0}})) ==
         RuntimeQueueDecision::kQueued);
  assert(runtime.QueueInput(
             Binding(), Input(*grant, 2, {MoveEvent{1, 1}})) ==
         RuntimeQueueDecision::kRevoked);
  assert(runtime.state() == RuntimeState::kIdle);
}

class BlockingHashes final : public HashProvider {
 public:
  std::optional<std::string> Sha256Hex(std::string_view) override {
    {
      std::lock_guard<std::mutex> lock(mutex);
      entered = true;
    }
    changed.notify_all();
    std::unique_lock<std::mutex> lock(mutex);
    changed.wait(lock, [&] { return proceed; });
    return kHash;
  }
  std::mutex mutex;
  std::condition_variable changed;
  bool entered = false;
  bool proceed = false;
};

void ClipboardNetworkAndLocalActionsShareOneNativeLane() {
  FakeInput input;
  FakeSecrets secrets;
  BlockingHashes hashes;
  FakeSafety process_privilege;
  FakeSafety desktop;
  FakeSafety banner;
  FakeHotkey hotkey;
  FakeRaw raw;
  FakeClock clock;
  RemoteControlRuntime runtime(input, secrets, hashes, process_privilege,
                               desktop, banner, hotkey, raw, clock);
  runtime.BindClipboardCall(Binding(), CapabilityBit(Capability::kClipboard));
  const ClipboardOfferMessage offer{"0011223344556677", kHash, 5};
  assert(runtime.ObserveClipboardOffer(Binding(), offer) ==
         ClipboardDecision::kPrompt);

  std::atomic<bool> accept_returned{false};
  ClipboardDecision received = ClipboardDecision::kInvalid;
  std::optional<AcceptedClipboard> accepted;
  std::thread receive([&] {
    received = runtime.ReceiveClipboardData(
        Binding(), ClipboardDataMessage{offer.id, offer.sha256, "hello"});
  });
  {
    std::unique_lock<std::mutex> lock(hashes.mutex);
    hashes.changed.wait(lock, [&] { return hashes.entered; });
  }
  std::thread accept([&] {
    accepted = runtime.AcceptClipboard(offer.id);
    accept_returned = true;
  });
  std::this_thread::yield();
  assert(!accept_returned.load());
  {
    std::lock_guard<std::mutex> lock(hashes.mutex);
    hashes.proceed = true;
  }
  hashes.changed.notify_all();
  receive.join();
  accept.join();
  assert(received == ClipboardDecision::kReady);
  assert(accepted && accepted->sender == Binding());
  assert(accepted->id == offer.id);
  assert(accepted->text == "hello");
}

void RealWin32WrappersHaveSafeEmptyBehavior() {
  Win32BannerVisibilityProbe banner;
  assert(banner.Observe() == SafetyObservation::kUnknown);
  Win32KillHotkeyRegistrar hotkey;
  assert(!hotkey.Register(nullptr, 1, MOD_CONTROL, VK_ESCAPE));
  Win32RawInputMonitor raw;
  assert(!raw.Register(nullptr));
  assert(raw.Classify(0) == RawInputOrigin::kUnknown);
  Win32MonotonicClock clock;
  const auto first = clock.NowMs();
  const auto second = clock.NowMs();
  assert(second >= first);
}

// M10 audit 2026-07-27 (hardware-verified premise): hotkeys are thread-affine,
// so the daemon-thread revoke must PARK the unregistration for the UI thread
// instead of firing it inline, and a refused unregister must stay pending.
void HotkeyCleanupIsDeferredAndRetriedOnTheOwnerThread() {
  Harness harness;
  assert(harness.Activate());
  assert(harness.runtime.hotkey_available());
  assert(harness.runtime.Stop());
  // Revoke parks the cleanup; nothing may unregister inline.
  assert(harness.hotkey.unregistered.empty());

  // First drain attempt is refused (simulates any transient OS failure):
  // the obligation must survive.
  harness.hotkey.unregister_ok = false;
  harness.runtime.PollSafety();
  assert(harness.hotkey.unregistered.empty());

  harness.hotkey.unregister_ok = true;
  harness.runtime.PollSafety();
  assert(harness.hotkey.unregistered ==
         std::vector<int>{harness.config.preferred_hotkey.id});

  // A second session can register the same id again afterwards.
  harness.hotkey.results = {true};
  assert(harness.Activate());
  assert(harness.runtime.hotkey_available());
  assert(harness.runtime.Stop());

  // The next Activate drains a still-parked cleanup before registering.
  Harness back_to_back;
  assert(back_to_back.Activate());
  assert(back_to_back.runtime.Stop());
  assert(back_to_back.hotkey.unregistered.empty());
  back_to_back.hotkey.results = {true};
  assert(back_to_back.Activate());
  assert(back_to_back.hotkey.unregistered ==
         std::vector<int>{back_to_back.config.preferred_hotkey.id});
}

// A kill intent must never outlive the press that raised it. Every path that
// raises one has to answer it, or the watermark refuses every later drain and
// the session silently stops responding without ever ending.
void EveryKillIntentIsAnswered() {
  // (a) The panic key pressed while the OTHER id of the pair is the live
  // registration. Earlier this raised an intent that nothing acknowledged:
  // input died, state stayed active, the peer was never told.
  Harness harness;
  harness.hotkey.results = {false, true};  // preferred fails -> fallback live
  const auto grant = harness.Activate();
  assert(grant);
  assert(harness.runtime.state() == RuntimeState::kActive);
  assert(harness.runtime.HandleWindowMessage(
      WM_HOTKEY, static_cast<WPARAM>(harness.config.preferred_hotkey.id), 0));
  assert(harness.runtime.state() == RuntimeState::kIdle);  // it really stopped
  assert(harness.events.back().type == RuntimeEventType::kRevoked);
  // (A "next session drains fine" block used to sit here as the supposed proof
  // that the intent was answered. It could not fail: a fresh Harness owns a
  // fresh policy, so it never saw this intent. The two asserts above are the
  // real detector — narrowing the revoke back to the registered id fails them.)

  // (b) A stop whose binding does not match must leave the live session
  // completely alone: it must not strand an intent on it, and — since it does
  // not raise one at all — must not truncate its queue or release its keys.
  Harness other;
  const auto live = other.Activate();
  assert(live);
  // Drain a key-DOWN first so the session genuinely holds a key. Without this
  // the "no collateral release" assert below is theatre: held_keys_ would be
  // empty whatever StopIfBinding did, so no mutation could ever fail it.
  assert(other.runtime.QueueInput(
             Binding(), Input(*live, 1, {KeyEvent{66, true}})) ==
         RuntimeQueueDecision::kQueued);
  assert(other.runtime.DrainOne() == DrainDecision::kApplied);

  // A second batch is queued when the unrelated stop arrives.
  assert(other.runtime.QueueInput(
             Binding(), Input(*live, 2, {KeyEvent{67, true}})) ==
         RuntimeQueueDecision::kQueued);
  SessionBinding stranger{"call-z", kAccount, kDevice, 7};
  assert(!other.runtime.StopIfBinding(stranger, live->epoch));
  assert(other.runtime.state() == RuntimeState::kActive);
  // The queued batch survives and still applies...
  assert(other.runtime.DrainOne() == DrainDecision::kApplied);
  assert(other.input.apply_calls == 2);
  assert(other.input.released_keys.empty());  // nothing released mid-session

  // ...and BOTH keys were still genuinely held, which only a real stop
  // releases. This is what makes the assert above more than decoration: a
  // truncation would have moved them to the pending set early.
  assert(other.runtime.Stop());
  auto released = other.input.released_keys;
  std::sort(released.begin(), released.end());
  assert((released == std::vector<std::uint16_t>{66, 67}));
}

// Two sessions whose cleanups BOTH fail to drain: the obligations must
// accumulate, and neither id may be handed out again while the OS still holds
// it. A single pending slot dropped the older one and leaked that combo for
// the process lifetime.
void OwedHotkeysAccumulateAndAreNeverReRegisteredWhileOwed() {
  Harness harness;
  harness.hotkey.results = {true};
  assert(harness.Activate());
  assert(harness.runtime.hotkey_available());

  // Session 1 ends; the drain is refused, so the preferred id stays owed.
  harness.hotkey.unregister_ok = false;
  assert(harness.runtime.Stop());
  harness.runtime.PollSafety();
  assert(harness.hotkey.unregistered.empty());

  // Session 2 must NOT claim the still-owed preferred id; it takes the
  // fallback instead and reports a live kill switch honestly.
  harness.hotkey.results = {true};
  assert(harness.Activate());
  assert(harness.runtime.hotkey_available());
  assert(harness.hotkey.attempts.back().id == harness.config.fallback_hotkey.id);

  // Session 2 ends: the fallback obligation must be ADDED, not overwrite the
  // preferred one. Let the drains succeed and require both back.
  assert(harness.runtime.Stop());
  harness.hotkey.unregister_ok = true;
  harness.runtime.PollSafety();
  auto released = harness.hotkey.unregistered;
  std::sort(released.begin(), released.end());
  auto expected = std::vector<int>{harness.config.preferred_hotkey.id,
                                   harness.config.fallback_hotkey.id};
  std::sort(expected.begin(), expected.end());
  assert(released == expected);
  assert(harness.hotkey.live.empty());  // nothing leaked to the "OS"
}

// M10 audit 2026-07-27: a release retained on the secure desktop was only
// retried once the session went kIdle. Suspended-for-another-reason (hidden
// banner after UAC) latched the key indefinitely.
void RetainedReleasesRetryWhileSuspendedForAnotherReason() {
  Harness harness;
  const auto grant = harness.Activate();
  assert(grant);
  assert(harness.runtime.QueueInput(
             Binding(), Input(*grant, 1, {KeyEvent{17, true}})) ==
         RuntimeQueueDecision::kQueued);
  assert(harness.runtime.DrainOne() == DrainDecision::kApplied);
  assert(harness.input.released_keys.empty());

  // Secure desktop: suspend retains the obligation (release refused there).
  harness.desktop.observation = SafetyObservation::kUnsafe;
  harness.runtime.PollSafety();
  assert(harness.runtime.state() == RuntimeState::kSuspended);
  assert(harness.input.released_keys.empty());

  // Ordinary desktop returns while the banner is occluded: the session stays
  // suspended for the other reason, but the retained key must release now.
  harness.desktop.observation = SafetyObservation::kSafe;
  harness.banner.observation = SafetyObservation::kUnsafe;
  harness.runtime.PollSafety();
  assert(harness.runtime.state() == RuntimeState::kSuspended);
  assert(harness.input.released_keys == std::vector<std::uint16_t>{17});
}

void ProtectedSurfaceRevokesQueuedAndNewInput() {
  Harness h;
  const auto grant = h.Activate();
  assert(grant);
  assert(h.runtime.QueueInput(Binding(), Input(*grant, 1,
      {KeyEvent{17, true}, ButtonEvent{MouseButton::kLeft, true}})) ==
      RuntimeQueueDecision::kQueued);
  assert(h.runtime.DrainOne() == DrainDecision::kApplied);
  assert(h.runtime.QueueInput(Binding(), Input(*grant, 2,
      {MoveEvent{0, 0}})) == RuntimeQueueDecision::kQueued);
  assert(h.runtime.SetInputBlocked(true));
  assert(h.runtime.AuthorityStatus().release_complete);
  assert(!h.runtime.AuthorityStatus().grant.active);
  assert(h.input.released_keys == std::vector<std::uint16_t>{17});
  assert(h.input.released_buttons == std::vector<MouseButton>{MouseButton::kLeft});
  assert(h.runtime.DrainOne() == DrainDecision::kEmpty);
  assert(h.runtime.QueueInput(Binding(), Input(*grant, 3,
      {MoveEvent{1, 1}})) == RuntimeQueueDecision::kRejected);
  assert(h.input.apply_calls == 2);
  assert(h.runtime.Stop());  // A confirmed stop is idempotent.
  assert(h.runtime.SetInputBlocked(false, UINT64_MAX, h.runtime.block_generation()));
  const auto replacement = h.Activate();
  assert(replacement && replacement->epoch != grant->epoch);
  assert(h.runtime.QueueInput(Binding(), Input(*grant, 4,
      {MoveEvent{1, 1}})) == RuntimeQueueDecision::kRejected);
}

void FailedReleaseRemainsUnacknowledgedAndPreventsActivation() {
  Harness h;
  const auto grant = h.Activate();
  assert(grant);
  assert(h.runtime.QueueInput(Binding(), Input(*grant, 1,
      {KeyEvent{17, true}})) == RuntimeQueueDecision::kQueued);
  assert(h.runtime.DrainOne() == DrainDecision::kApplied);
  h.input.release_ok = false;
  assert(!h.runtime.SetInputBlocked(true));
  assert(!h.runtime.AuthorityStatus().grant.active);
  assert(!h.runtime.AuthorityStatus().release_complete);
  assert(!h.runtime.Stop());
  assert(!h.runtime.SetInputBlocked(false, UINT64_MAX, h.runtime.block_generation()));
  assert(!h.Activate());
  h.input.release_ok = true;
  h.runtime.PollSafety();
  assert(h.runtime.AuthorityStatus().release_complete);
  assert(h.runtime.SetInputBlocked(false, UINT64_MAX, h.runtime.block_generation()));
  assert(h.Activate());
}

void SurfaceBlockInterruptsAnInFlightBatchBeforeAcknowledgement() {
  Harness h;
  const auto grant = h.Activate();
  assert(grant);
  assert(h.runtime.QueueInput(Binding(), Input(*grant, 1,
      {KeyEvent{17, true}, MoveEvent{0, 0}, KeyEvent{17, false}})) ==
      RuntimeQueueDecision::kQueued);
  h.input.block_apply = true;
  std::thread injection([&] { h.runtime.DrainOne(); });
  {
    std::unique_lock<std::mutex> lock(h.input.apply_mutex);
    h.input.apply_changed.wait(lock, [&] { return h.input.apply_entered; });
  }
  std::atomic<bool> acknowledged{false};
  std::thread revoke([&] {
    assert(h.runtime.SetInputBlocked(true));
    acknowledged = true;
  });
  while (h.runtime.InputAllowed()) std::this_thread::yield();
  assert(!acknowledged);
  {
    std::lock_guard<std::mutex> lock(h.input.apply_mutex);
    h.input.allow_apply = true;
  }
  h.input.apply_changed.notify_all();
  injection.join();
  revoke.join();
  assert(acknowledged && h.input.apply_calls == 1);
  assert(h.input.released_keys == std::vector<std::uint16_t>{17});
  assert(h.runtime.QueueInput(Binding(), Input(*grant, 2,
      {MoveEvent{1, 1}})) == RuntimeQueueDecision::kRejected);
}

void LeaseExpiryIsCheckedBetweenInputPrimitives() {
  Harness h;
  assert(h.runtime.SetInputBlocked(false, 1100, h.runtime.block_generation()));
  const auto grant = h.Activate();
  assert(grant);
  assert(h.runtime.QueueInput(Binding(), Input(*grant, 1,
      {KeyEvent{17, true}, MoveEvent{0, 0}, KeyEvent{17, false}})) ==
      RuntimeQueueDecision::kQueued);
  h.input.on_apply = [&] { h.clock.now = 1100; };
  h.runtime.DrainOne();
  assert(h.input.apply_calls == 1);
  assert(!h.runtime.AuthorityStatus().grant.active);
  assert(!h.runtime.InputAllowed());
  assert(!h.runtime.SetInputBlocked(false, 3000, h.runtime.block_generation()));
  const auto revoked = std::find_if(h.events.begin(), h.events.end(),
      [](const RuntimeEvent& event) { return event.type == RuntimeEventType::kRevoked; });
  assert(revoked != h.events.end());
  assert(revoked->binding == grant->binding && revoked->epoch == grant->epoch);
  assert(h.runtime.SetInputBlocked(true));
  assert(h.runtime.SetInputBlocked(false, 3000, h.runtime.block_generation()));
  assert(h.Activate());
}

void OlderUnblockCannotOverwriteANewerBlock() {
  Harness h;
  const auto old_generation = h.runtime.block_generation();
  // The caller reserved its permission update before this newer block. It
  // must not recapture the new generation when it eventually reaches runtime.
  h.runtime.BlockInput();
  assert(!h.runtime.SetInputBlocked(false, UINT64_MAX, old_generation));
  assert(!h.runtime.InputAllowed());
  assert(!h.Activate());
  assert(h.runtime.SetInputBlocked(true));
  assert(h.runtime.SetInputBlocked(false, UINT64_MAX,
                                   h.runtime.block_generation()));
  assert(h.Activate());
}

}  // namespace


// A deliberately suppressed packet was received and authenticated, so it
// consumes its sequence number without being queued or applied. Both pause
// causes (physical host priority, safety suspension) are covered.
void BeginPause(Harness& harness, bool physical) {
  if (physical) {
    assert(harness.runtime.HandleRawInput(1) == RawInputOrigin::kPhysical);
  } else {
    harness.banner.observation = SafetyObservation::kUnsafe;
    harness.runtime.PollSafety();
  }
  assert(harness.runtime.state() == RuntimeState::kSuspended);
}

void EndPause(Harness& harness, bool physical) {
  if (physical) {
    harness.clock.now = 1600;
  } else {
    harness.banner.observation = SafetyObservation::kSafe;
  }
  harness.runtime.PollSafety();
  assert(harness.runtime.state() == RuntimeState::kActive);
}

RuntimeQueueDecision PausedDecision(bool physical) {
  return physical ? RuntimeQueueDecision::kSuppressedByPhysicalHost
                  : RuntimeQueueDecision::kSuspended;
}

void SuppressedPacketsConsumeTheirSequenceForMode(bool physical) {
  const auto suppressed = PausedDecision(physical);
  {
    // One suppressed packet, then resume: the next packet is admitted.
    Harness harness;
    const auto grant = harness.Activate();
    assert(grant);
    assert(harness.runtime.QueueInput(
               Binding(), Input(*grant, 1, {KeyEvent{65, true}})) ==
           RuntimeQueueDecision::kQueued);
    assert(harness.runtime.DrainOne() == DrainDecision::kApplied);
    BeginPause(harness, physical);
    // The key held before the pause is released by the pause itself.
    assert(harness.input.released_keys == std::vector<std::uint16_t>{65});
    assert(harness.runtime.QueueInput(
               Binding(), Input(*grant, 2, {MoveEvent{0.5, 0.5}})) == suppressed);
    EndPause(harness, physical);
    assert(harness.runtime.QueueInput(
               Binding(), Input(*grant, 3, {MoveEvent{0.6, 0.6}})) ==
           RuntimeQueueDecision::kQueued);
    assert(harness.runtime.DrainOne() == DrainDecision::kApplied);
    assert(harness.runtime.DrainOne() == DrainDecision::kEmpty);
    // Applied: sequence 1 and sequence 3 only. Sequence 2 never runs.
    assert(harness.input.apply_calls == 2);
    assert(std::holds_alternative<MoveEvent>(harness.input.applied[1]));
    assert(std::get<MoveEvent>(harness.input.applied[1]).x == 0.6);
    assert(harness.input.released_keys == std::vector<std::uint16_t>{65});
    assert(harness.runtime.state() == RuntimeState::kActive);
  }
  {
    // Three contiguous suppressed packets, then resume.
    Harness harness;
    const auto grant = harness.Activate();
    assert(grant);
    BeginPause(harness, physical);
    for (std::uint64_t sequence = 1; sequence <= 3; ++sequence) {
      assert(harness.runtime.QueueInput(
                 Binding(), Input(*grant, sequence, {MoveEvent{0.9, 0.9}})) ==
             suppressed);
    }
    EndPause(harness, physical);
    assert(harness.runtime.QueueInput(
               Binding(), Input(*grant, 4, {MoveEvent{0.1, 0.1}})) ==
           RuntimeQueueDecision::kQueued);
    assert(harness.runtime.DrainOne() == DrainDecision::kApplied);
    assert(harness.input.apply_calls == 1);
    assert(harness.runtime.DrainOne() == DrainDecision::kEmpty);
  }
  {
    // A packet genuinely missing during the pause still revokes: after resume.
    Harness harness;
    const auto grant = harness.Activate();
    assert(grant);
    BeginPause(harness, physical);
    assert(harness.runtime.QueueInput(
               Binding(), Input(*grant, 1, {MoveEvent{0, 0}})) == suppressed);
    EndPause(harness, physical);
    assert(harness.runtime.QueueInput(
               Binding(), Input(*grant, 3, {MoveEvent{0, 0}})) ==
           RuntimeQueueDecision::kRevoked);
    assert(harness.runtime.state() == RuntimeState::kIdle);
    assert(harness.events.back().reason == RuntimeReason::kSequenceGap);
    assert(harness.input.apply_calls == 0);
  }
  {
    // ... and a gap seen while still paused revokes immediately.
    Harness harness;
    const auto grant = harness.Activate();
    assert(grant);
    BeginPause(harness, physical);
    assert(harness.runtime.QueueInput(
               Binding(), Input(*grant, 1, {MoveEvent{0, 0}})) == suppressed);
    assert(harness.runtime.QueueInput(
               Binding(), Input(*grant, 3, {MoveEvent{0, 0}})) ==
           RuntimeQueueDecision::kRevoked);
    assert(harness.runtime.state() == RuntimeState::kIdle);
    assert(harness.events.back().reason == RuntimeReason::kSequenceGap);
  }
  {
    // A duplicate of a suppressed sequence is ignored and never applied.
    Harness harness;
    const auto grant = harness.Activate();
    assert(grant);
    BeginPause(harness, physical);
    assert(harness.runtime.QueueInput(
               Binding(), Input(*grant, 1, {MoveEvent{0, 0}})) == suppressed);
    assert(harness.runtime.QueueInput(
               Binding(), Input(*grant, 1, {MoveEvent{0, 0}})) == suppressed);
    EndPause(harness, physical);
    assert(harness.runtime.QueueInput(
               Binding(), Input(*grant, 1, {MoveEvent{0, 0}})) ==
           RuntimeQueueDecision::kRejected);
    assert(harness.runtime.DrainOne() == DrainDecision::kEmpty);
    assert(harness.input.apply_calls == 0);
    assert(harness.runtime.state() == RuntimeState::kActive);
    assert(harness.runtime.QueueInput(
               Binding(), Input(*grant, 2, {MoveEvent{0, 0}})) ==
           RuntimeQueueDecision::kQueued);
  }
  {
    // Packets failing authentication during the pause do not advance it.
    Harness harness;
    const auto grant = harness.Activate();
    assert(grant);
    BeginPause(harness, physical);
    auto stale_token = Input(*grant, 1, {MoveEvent{0, 0}});
    stale_token.token[0] ^= 0x01;
    auto wrong_epoch = Input(*grant, 1, {MoveEvent{0, 0}});
    ++wrong_epoch.epoch;
    auto wrong_source = Input(*grant, 1, {MoveEvent{0, 0}});
    ++wrong_source.source_revision;
    SessionBinding wrong_sender = Binding();
    wrong_sender.call_id = "call-b";
    assert(harness.runtime.QueueInput(Binding(), stale_token) == suppressed);
    assert(harness.runtime.QueueInput(Binding(), wrong_epoch) == suppressed);
    assert(harness.runtime.QueueInput(Binding(), wrong_source) == suppressed);
    assert(harness.runtime.QueueInput(
               wrong_sender, Input(*grant, 1, {MoveEvent{0, 0}})) ==
           suppressed);
    EndPause(harness, physical);
    assert(harness.runtime.QueueInput(
               Binding(), Input(*grant, 1, {MoveEvent{0.2, 0.2}})) ==
           RuntimeQueueDecision::kQueued);
    assert(harness.runtime.DrainOne() == DrainDecision::kApplied);
    assert(harness.input.apply_calls == 1);
  }
  {
    // Revocation during the pause leaves nothing active to resume.
    Harness harness;
    const auto grant = harness.Activate();
    assert(grant);
    BeginPause(harness, physical);
    assert(harness.runtime.QueueInput(
               Binding(), Input(*grant, 1, {MoveEvent{0, 0}})) == suppressed);
    assert(harness.runtime.Stop());
    assert(harness.runtime.state() == RuntimeState::kIdle);
    if (physical) {
      harness.clock.now = 1600;
    } else {
      harness.banner.observation = SafetyObservation::kSafe;
    }
    harness.runtime.PollSafety();
    assert(harness.runtime.state() == RuntimeState::kIdle);
    assert(harness.runtime.QueueInput(
               Binding(), Input(*grant, 2, {MoveEvent{0, 0}})) ==
           RuntimeQueueDecision::kRejected);
    assert(harness.runtime.DrainOne() == DrainDecision::kEmpty);
    assert(harness.input.apply_calls == 0);
  }
}

void SuppressedPacketsConsumeTheirSequence() {
  SuppressedPacketsConsumeTheirSequenceForMode(true);
  SuppressedPacketsConsumeTheirSequenceForMode(false);
}


void SuppressedFloodExceedsTheRateLimitForMode(bool physical) {
  Harness harness;
  const auto grant = harness.Activate();
  assert(grant);
  BeginPause(harness, physical);
  const auto suppressed = PausedDecision(physical);
  // Validly sequenced packets in one second: the limit is 60 messages.
  for (std::uint64_t sequence = 1; sequence <= 60; ++sequence) {
    assert(harness.runtime.QueueInput(
               Binding(), Input(*grant, sequence, {MoveEvent{0, 0}})) ==
           suppressed);
  }
  assert(harness.runtime.QueueInput(
             Binding(), Input(*grant, 61, {MoveEvent{0, 0}})) ==
         RuntimeQueueDecision::kRevoked);
  assert(harness.runtime.state() == RuntimeState::kIdle);
  assert(!harness.runtime.AuthorityStatus().grant.active);
  assert(harness.events.back().type == RuntimeEventType::kRevoked);
  assert(harness.events.back().reason == RuntimeReason::kRateExceeded);
  assert(harness.input.apply_calls == 0);
}

void SuppressedCapabilityMismatchDoesNotAdvanceForMode(bool physical) {
  Harness harness;
  const auto grant = harness.Activate(
      static_cast<Capabilities>(CapabilityBit(Capability::kMouse)));
  assert(grant);
  BeginPause(harness, physical);
  // The grant lacks the keyboard capability: refused, sequence 1 not consumed.
  assert(harness.runtime.QueueInput(
             Binding(), Input(*grant, 1, {KeyEvent{65, true}})) ==
         PausedDecision(physical));
  EndPause(harness, physical);
  assert(harness.runtime.QueueInput(
             Binding(), Input(*grant, 1, {MoveEvent{0.3, 0.3}})) ==
         RuntimeQueueDecision::kQueued);
  assert(harness.runtime.DrainOne() == DrainDecision::kApplied);
  assert(harness.input.apply_calls == 1);
  assert(harness.runtime.state() == RuntimeState::kActive);
}

void SuppressedPauseReleasesAHeldMouseButtonForMode(bool physical) {
  Harness harness;
  const auto grant = harness.Activate();
  assert(grant);
  assert(harness.runtime.QueueInput(
             Binding(), Input(*grant, 1, {ButtonEvent{MouseButton::kLeft, true}})) ==
         RuntimeQueueDecision::kQueued);
  assert(harness.runtime.DrainOne() == DrainDecision::kApplied);
  BeginPause(harness, physical);
  assert(harness.input.released_buttons ==
         std::vector<MouseButton>{MouseButton::kLeft});
  assert(harness.runtime.QueueInput(
             Binding(), Input(*grant, 2, {MoveEvent{0.5, 0.5}})) ==
         PausedDecision(physical));
  EndPause(harness, physical);
  assert(harness.runtime.QueueInput(
             Binding(), Input(*grant, 3, {MoveEvent{0.6, 0.6}})) ==
         RuntimeQueueDecision::kQueued);
  assert(harness.runtime.DrainOne() == DrainDecision::kApplied);
  // Only the original press and the later move were applied: no re-press.
  assert(harness.input.apply_calls == 2);
  assert(std::holds_alternative<ButtonEvent>(harness.input.applied[0]));
  assert(std::holds_alternative<MoveEvent>(harness.input.applied[1]));
  assert(harness.input.released_buttons ==
         std::vector<MouseButton>{MouseButton::kLeft});
}

void SuppressedPathEnforcesRateCapabilityAndButtonRelease() {
  for (const bool physical : {true, false}) {
    SuppressedFloodExceedsTheRateLimitForMode(physical);
    SuppressedCapabilityMismatchDoesNotAdvanceForMode(physical);
    SuppressedPauseReleasesAHeldMouseButtonForMode(physical);
  }
}

int main() {
  // RC6: a runtime has no surface permission until the channel establishes it.
  {
    Harness unknown(false);
    assert(!unknown.Activate());
  }
  ProtectedSurfaceRevokesQueuedAndNewInput();
  FailedReleaseRemainsUnacknowledgedAndPreventsActivation();
  SurfaceBlockInterruptsAnInFlightBatchBeforeAcknowledgement();
  LeaseExpiryIsCheckedBetweenInputPrimitives();
  OlderUnblockCannotOverwriteANewerBlock();
  ProcessPrivilegeIsClassifiedAndEnforcedFailClosed();
  ActivationIsDefaultDenyAndFallbackIsVisible();
  InputIsCheckedBeforeQueueAndEveryApply();
  PhysicalInputSuppressesAndReleasesRemoteHolds();
  SuppressedPacketsConsumeTheirSequence();
  SuppressedPathEnforcesRateCapabilityAndButtonRelease();
  HotkeyCleanupIsDeferredAndRetriedOnTheOwnerThread();
  EveryKillIntentIsAnswered();
  OwedHotkeysAccumulateAndAreNeverReRegisteredWhileOwed();
  RetainedReleasesRetryWhileSuspendedForAnotherReason();
  CoControlKeepsBothLocalAndRemoteInputLive();
  StaleBindingCannotMutateAReplacementSession();
  ScopedStopPreemptsTheMatchingInFlightBatch();
  ActivationCanStartInLocallyApprovedCoControl();
  HotkeyAndQueuePressureRevokeNativeAuthority();
  ClipboardNetworkAndLocalActionsShareOneNativeLane();
  RealWin32WrappersHaveSafeEmptyBehavior();
}
