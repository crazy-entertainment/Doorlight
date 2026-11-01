#ifdef NDEBUG
#undef NDEBUG
#endif

#include "remote_control_policy.h"

#include <atomic>
#include <cassert>
#include <condition_variable>
#include <mutex>
#include <string>
#include <thread>
#include <vector>

using namespace sybl::remote;

namespace {

constexpr auto kAccount = "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa";
constexpr auto kOtherAccount = "bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb";
constexpr auto kDevice =
    "1111111111111111111111111111111111111111111111111111111111111111";
constexpr auto kOtherDevice =
    "2222222222222222222222222222222222222222222222222222222222222222";
constexpr auto kHash =
    "0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef";

SessionBinding Binding(std::uint64_t revision = 7) {
  return {"call-a", kAccount, kDevice, revision};
}

DesktopRect VirtualDesktop() {
  return {-1920, 0, 3840, 1080};
}

DesktopRect LeftMonitor() {
  return {-1920, 0, 1920, 1080};
}

class FakeSecrets final : public SecretSource {
 public:
  std::optional<std::string> GenerateHex(std::size_t bytes) override {
    assert(bytes == 16);
    ++counter;
    return counter == 1 ? "00112233445566778899aabbccddeeff"
                        : "ffeeddccbbaa99887766554433221100";
  }
  int counter = 0;
};

class RepeatingSecrets final : public SecretSource {
 public:
  std::optional<std::string> GenerateHex(std::size_t bytes) override {
    assert(bytes == 16);
    return "00112233445566778899aabbccddeeff";
  }
};

class FakeHashes final : public HashProvider {
 public:
  std::optional<std::string> Sha256Hex(std::string_view bytes) override {
    last = std::string(bytes);
    return fail ? std::optional<std::string>{"f" + std::string(63, '0')}
                : std::optional<std::string>{kHash};
  }
  bool fail = false;
  std::string last;
};

class RecordingAdapter : public InputAdapter {
 public:
  bool Apply(const InputEvent& event,
             const DesktopRect&,
             const DesktopRect&) override {
    applied.push_back(event);
    return apply_ok;
  }
  bool ReleaseKey(std::uint16_t virtual_key) override {
    released_keys.push_back(virtual_key);
    return release_ok;
  }
  bool ReleaseButton(MouseButton button) override {
    released_buttons.push_back(button);
    return release_ok;
  }

  bool apply_ok = true;
  bool release_ok = true;
  std::vector<InputEvent> applied;
  std::vector<std::uint16_t> released_keys;
  std::vector<MouseButton> released_buttons;
};

InputMessage Input(const ActiveGrant& grant,
                   std::uint64_t sequence,
                   std::vector<InputEvent> events) {
  return {grant.token, grant.epoch, sequence, grant.binding.source_revision,
          std::move(events)};
}

ActiveGrant Activate(RemoteControlPolicy& policy,
                     FakeSecrets& secrets,
                     Capabilities capabilities =
                         static_cast<Capabilities>(
                             CapabilityBit(Capability::kMouse) |
                             CapabilityBit(Capability::kKeyboard) |
                             CapabilityBit(Capability::kText))) {
  const auto grant = policy.Activate(Binding(), LeftMonitor(), VirtualDesktop(),
                                     capabilities, secrets);
  assert(grant);
  return *grant;
}

void MappingHandlesNegativeVirtualOrigins() {
  const auto top_left =
      MapToVirtualDesktop(MoveEvent{0, 0}, LeftMonitor(), VirtualDesktop());
  const auto bottom_right =
      MapToVirtualDesktop(MoveEvent{1, 1}, LeftMonitor(), VirtualDesktop());
  assert(top_left && top_left->x == 0 && top_left->y == 0);
  assert(bottom_right);
  assert(bottom_right->x > 32700 && bottom_right->x < 32800);
  assert(bottom_right->y == 65535);
  const auto primary = MapToVirtualDesktop(
      MoveEvent{0, 0}, DesktopRect{0, 0, 1920, 1080}, VirtualDesktop());
  assert(primary && primary->x > 32700 && primary->x < 32850);
  assert(!MapToVirtualDesktop(MoveEvent{-0.1, 0}, LeftMonitor(), VirtualDesktop()));
  assert(!MapToVirtualDesktop(MoveEvent{0, 0},
                              DesktopRect{-3000, 0, 1920, 1080},
                              VirtualDesktop()));
}

void RequestAntiNagIsPerBoundSourceSession() {
  PolicyLimits limits;
  limits.request_dedupe_ms = 100;
  limits.max_requests_per_call = 2;
  RemoteControlPolicy policy(limits);
  assert(policy.ObserveRequest(Binding(), 1000) == RequestDecision::kPrompt);
  assert(policy.ObserveRequest(Binding(), 1050) == RequestDecision::kDuplicate);
  assert(policy.ObserveRequest(Binding(), 1100) == RequestDecision::kPrompt);
  assert(policy.ObserveRequest(Binding(), 1200) == RequestDecision::kCapped);
  assert(policy.ObserveRequest(Binding(8), 1201) == RequestDecision::kPrompt);
  auto invalid = Binding();
  invalid.controller_device.clear();
  assert(policy.ObserveRequest(invalid, 1300) == RequestDecision::kInvalid);
}

void GrantTokensAreFreshAndEveryGateFailsClosed() {
  RemoteControlPolicy policy;
  FakeSecrets secrets;
  RecordingAdapter adapter;
  const auto first = Activate(policy, secrets);
  assert(first.active && !first.suspended && first.epoch > 0);

  auto message = Input(first, 1, {MoveEvent{0.5, 0.5}});
  auto sender = Binding();
  auto wrong_sender = sender;
  wrong_sender.controller_account = kOtherAccount;
  assert(policy.Queue(wrong_sender, message, 1) ==
         QueueDecision::kBindingMismatch);
  wrong_sender = sender;
  wrong_sender.controller_device = kOtherDevice;
  assert(policy.Queue(wrong_sender, message, 1) ==
         QueueDecision::kBindingMismatch);
  auto wrong_call = sender;
  wrong_call.call_id = "call-b";
  assert(policy.Queue(wrong_call, message, 1) ==
         QueueDecision::kBindingMismatch);
  auto wrong_token = message;
  wrong_token.token[0] = 'f';
  assert(policy.Queue(sender, wrong_token, 1) ==
         QueueDecision::kTokenMismatch);
  auto wrong_epoch = message;
  ++wrong_epoch.epoch;
  assert(policy.Queue(sender, wrong_epoch, 1) ==
         QueueDecision::kEpochMismatch);
  auto wrong_source = message;
  ++wrong_source.source_revision;
  assert(policy.Queue(sender, wrong_source, 1) ==
         QueueDecision::kSourceMismatch);

  assert(policy.Queue(sender, message, 1) == QueueDecision::kQueued);
  assert(policy.DrainOne(adapter) == DrainDecision::kApplied);
  assert(adapter.applied.size() == 1);
  assert(policy.Queue(sender, message, 2) ==
         QueueDecision::kDuplicateOrOutOfOrder);

  assert(policy.Revoke(adapter));
  assert(!policy.Snapshot().active);
  assert(policy.Queue(sender, Input(first, 2, {MoveEvent{0, 0}}), 3) ==
         QueueDecision::kInactive);
  const auto second = Activate(policy, secrets);
  assert(first.token != second.token);
  assert(second.epoch > first.epoch);

  RemoteControlPolicy repeated_policy;
  RepeatingSecrets repeated;
  const auto repeated_first =
      repeated_policy.Activate(Binding(), LeftMonitor(), VirtualDesktop(),
                               CapabilityBit(Capability::kMouse), repeated);
  assert(repeated_first);
  assert(repeated_policy.Revoke(adapter));
  assert(!repeated_policy.Activate(Binding(), LeftMonitor(), VirtualDesktop(),
                                   CapabilityBit(Capability::kMouse), repeated));
}

void CapabilitiesAndQueuePressureFailClosed() {
  FakeSecrets secrets;
  RecordingAdapter adapter;
  RemoteControlPolicy mouse_only;
  const auto grant =
      Activate(mouse_only, secrets, CapabilityBit(Capability::kMouse));
  assert(mouse_only.Queue(Binding(),
                          Input(grant, 1, {KeyEvent{65, true}}), 1) ==
         QueueDecision::kCapabilityMismatch);
  assert(mouse_only.Queue(Binding(),
                          Input(grant, 1, {TextEvent{"hello"}}), 1) ==
         QueueDecision::kCapabilityMismatch);

  PolicyLimits limits;
  limits.max_queued_batches = 1;
  RemoteControlPolicy bounded(limits);
  FakeSecrets bounded_secrets;
  const auto bounded_grant = Activate(bounded, bounded_secrets);
  assert(bounded.Queue(Binding(),
                       Input(bounded_grant, 1, {MoveEvent{0, 0}}), 1) ==
         QueueDecision::kQueued);
  assert(bounded.Queue(Binding(),
                       Input(bounded_grant, 2, {MoveEvent{1, 1}}), 1) ==
         QueueDecision::kQueueFullRevoke);
  assert(!bounded.Snapshot().active);
  assert(bounded.queued_batches() == 0);

  PolicyLimits attempt_limits;
  attempt_limits.max_messages_per_second = 1;
  RemoteControlPolicy attempts(attempt_limits);
  FakeSecrets attempt_secrets;
  const auto attempt_grant = Activate(attempts, attempt_secrets);
  auto stale_token =
      Input(attempt_grant, 1, {MoveEvent{0.5, 0.5}});
  stale_token.token[0] = stale_token.token[0] == 'f' ? 'e' : 'f';
  assert(attempts.Queue(Binding(), stale_token, 20) ==
         QueueDecision::kTokenMismatch);
  assert(attempts.Snapshot().active);
  stale_token.sequence = 2;
  assert(attempts.Queue(Binding(), stale_token, 21) ==
         QueueDecision::kRateExceededRevoke);
  assert(!attempts.Snapshot().active);
}

void HeldInputsReleaseOnSuspendResumeRevokeAndRateFailure() {
  FakeSecrets secrets;
  RecordingAdapter adapter;
  RemoteControlPolicy policy;
  const auto grant = Activate(policy, secrets);
  assert(policy.Queue(Binding(),
                      Input(grant, 1,
                            {KeyEvent{65, true},
                             ButtonEvent{MouseButton::kLeft, true}}),
                      1) == QueueDecision::kQueued);
  assert(policy.DrainOne(adapter) == DrainDecision::kApplied);
  assert(policy.held_keys() == 1 && policy.held_buttons() == 1);
  assert(policy.Suspend());
  assert(policy.Snapshot().suspended);
  assert(policy.Resume(adapter));
  assert(!policy.Snapshot().suspended);
  assert(adapter.released_keys == std::vector<std::uint16_t>{65});
  assert(adapter.released_buttons ==
         std::vector<MouseButton>{MouseButton::kLeft});

  const auto live = policy.Snapshot();
  assert(policy.Queue(Binding(),
                      Input(live, 2, {KeyEvent{66, true}}), 2) ==
         QueueDecision::kQueued);
  assert(policy.DrainOne(adapter) == DrainDecision::kApplied);
  adapter.release_ok = false;
  assert(!policy.Revoke(adapter));
  adapter.release_ok = true;
  assert(policy.ReleasePending(adapter));
  assert(adapter.released_keys.back() == 66);

  PolicyLimits rate_limits;
  rate_limits.max_messages_per_second = 1;
  rate_limits.max_events_per_second = 10;
  RemoteControlPolicy rate_policy(rate_limits);
  FakeSecrets rate_secrets;
  RecordingAdapter rate_adapter;
  const auto rate_grant = Activate(rate_policy, rate_secrets);
  assert(rate_policy.Queue(Binding(),
                           Input(rate_grant, 1, {KeyEvent{67, true}}), 10) ==
         QueueDecision::kQueued);
  assert(rate_policy.DrainOne(rate_adapter) == DrainDecision::kApplied);
  assert(rate_policy.Queue(Binding(),
                           Input(rate_grant, 2, {MoveEvent{0, 0}}), 11) ==
         QueueDecision::kRateExceededRevoke);
  assert(!rate_policy.Snapshot().active);
  assert(rate_policy.ReleasePending(rate_adapter));
  assert(rate_adapter.released_keys.back() == 67);
}

class BlockingAdapter final : public RecordingAdapter {
 public:
  bool Apply(const InputEvent& event,
             const DesktopRect& source,
             const DesktopRect& virtual_desktop) override {
    {
      std::lock_guard<std::mutex> lock(block_mutex);
      entered = true;
    }
    changed.notify_all();
    std::unique_lock<std::mutex> lock(block_mutex);
    changed.wait(lock, [this] { return proceed; });
    lock.unlock();
    return RecordingAdapter::Apply(event, source, virtual_desktop);
  }

  std::mutex block_mutex;
  std::condition_variable changed;
  bool entered = false;
  bool proceed = false;
};

void RevokeCannotRacePastAnApplyingEvent() {
  RemoteControlPolicy policy;
  FakeSecrets secrets;
  BlockingAdapter adapter;
  const auto grant = Activate(policy, secrets);
  assert(policy.Queue(Binding(),
                      Input(grant, 1, {KeyEvent{70, true}}), 1) ==
         QueueDecision::kQueued);

  std::atomic<bool> revoke_returned{false};
  std::thread drain([&] {
    assert(policy.DrainOne(adapter) == DrainDecision::kApplied);
  });
  {
    std::unique_lock<std::mutex> lock(adapter.block_mutex);
    adapter.changed.wait(lock, [&] { return adapter.entered; });
  }
  std::thread revoke([&] {
    policy.Revoke(adapter);
    revoke_returned = true;
  });
  std::this_thread::yield();
  assert(!revoke_returned.load());
  {
    std::lock_guard<std::mutex> lock(adapter.block_mutex);
    adapter.proceed = true;
  }
  adapter.changed.notify_all();
  drain.join();
  revoke.join();
  assert(revoke_returned.load());
  assert(!policy.Snapshot().active);
  assert(adapter.released_keys == std::vector<std::uint16_t>{70});
}

void ClipboardOfferLifetimeIsBounded() {
  ClipboardConsentPolicy clipboard;
  const auto binding = Binding();
  clipboard.BindCall(binding, CapabilityBit(Capability::kClipboard));
  const auto id = [](int i) { const auto value = std::to_string(i); return std::string(16 - value.size(), '0') + value; };
  assert(clipboard.ObserveOffer(binding, {id(0), kHash, 5}, 1000) == ClipboardDecision::kPrompt);
  assert(clipboard.ObserveOffer(binding, {id(1), kHash, 5}, 1001) == ClipboardDecision::kBusy);
  assert(clipboard.Reject(id(0)) == ClipboardDecision::kRejected);
  assert(clipboard.ObserveOffer(binding, {id(1), kHash, 5}, 1002) == ClipboardDecision::kDuplicate);
  for (int i = 2; i < 64; ++i) {
    assert(clipboard.ObserveOffer(binding, {id(i), kHash, 5}, 1003) == ClipboardDecision::kPrompt);
    assert(clipboard.Reject(id(i)) == ClipboardDecision::kRejected);
  }
  assert(clipboard.ObserveOffer(binding, {id(64), kHash, 5}, 1004) == ClipboardDecision::kBusy);
  assert(clipboard.ObserveOffer(binding, {id(0), kHash, 5}, 1005) == ClipboardDecision::kDuplicate);
}

void ClipboardConsentBindsIdHashBytesAndTimeout() {
  PolicyLimits limits;
  limits.clipboard_timeout_ms = 100;
  ClipboardConsentPolicy clipboard(limits);
  const auto binding = Binding();
  clipboard.BindCall(binding, CapabilityBit(Capability::kClipboard));
  ClipboardOfferMessage offer{"0011223344556677", kHash, 5};
  assert(clipboard.ObserveOffer(binding, offer, 1000) ==
         ClipboardDecision::kPrompt);
  assert(clipboard.ObserveOffer(binding, offer, 1001) ==
         ClipboardDecision::kDuplicate);
  assert(clipboard.ObserveOffer(
             binding,
             ClipboardOfferMessage{"8899aabbccddeeff", kHash, 5}, 1002) ==
         ClipboardDecision::kBusy);

  FakeHashes hashes;
  assert(clipboard.ReceiveData(
             binding,
             ClipboardDataMessage{"8899aabbccddeeff", offer.sha256, "hello"},
             1003, hashes) == ClipboardDecision::kInvalid);
  // A crossed/late id must not evict the valid transaction.
  assert(!clipboard.Preview(offer.id, 1003));
  assert(clipboard.ReceiveData(
             binding,
             ClipboardDataMessage{offer.id, offer.sha256, "hello"},
             1004, hashes) == ClipboardDecision::kReady);
  assert(hashes.last == "hello");
  assert(clipboard.Preview(offer.id, 1005) ==
         std::optional<std::string>{"hello"});
  const auto accepted = clipboard.Accept(offer.id, 1005);
  assert(accepted && accepted->sender == binding);
  assert(accepted->id == offer.id);
  assert(accepted->text == "hello");
  assert(!clipboard.Accept(offer.id, 1005));
  assert(clipboard.ObserveOffer(binding, offer, 2000) == ClipboardDecision::kDuplicate);
  offer.id = "1122334455667788";

  assert(clipboard.ObserveOffer(binding, offer, 2000) ==
         ClipboardDecision::kPrompt);
  hashes.fail = true;
  assert(clipboard.ReceiveData(
             binding,
             ClipboardDataMessage{offer.id, offer.sha256, "hello"},
             2001, hashes) == ClipboardDecision::kHashMismatch);

  assert(clipboard.ObserveOffer(binding, offer, 3000) == ClipboardDecision::kDuplicate);
  offer.id = "2233445566778899";
  assert(clipboard.ObserveOffer(binding, offer, 3000) ==
         ClipboardDecision::kPrompt);
  hashes.fail = false;
  assert(clipboard.ReceiveData(
             binding,
             ClipboardDataMessage{offer.id, offer.sha256, "hello"},
             3100, hashes) == ClipboardDecision::kExpired);

  auto wrong = binding;
  wrong.controller_device = kOtherDevice;
  assert(clipboard.ObserveOffer(wrong, offer, 4000) ==
         ClipboardDecision::kBindingMismatch);
  clipboard.EndCall();
  assert(clipboard.ObserveOffer(binding, offer, 4001) ==
         ClipboardDecision::kBindingMismatch);
}

// M10 audit 2026-07-27: the surface identity must bind the device name and
// BOTH geometries. A moved virtual desktop with a byte-identical source rect
// silently redirected absolute injection onto an unshared display, and two
// same-size monitors trading places were indistinguishable by rect alone.
void SurfaceIdentityBindsDeviceAndBothGeometries() {
  const ResolvedSurface granted{
      {0, 0, 1920, 1080}, {0, 0, 3840, 1080}, L"\\\\.\\DISPLAY1"};
  assert(SameSurface(granted, granted));

  auto moved_desktop = granted;
  moved_desktop.virtual_desktop.left = -1920;
  assert(!SameSurface(granted, moved_desktop));

  auto shrunk_desktop = granted;
  shrunk_desktop.virtual_desktop.width = 1920;
  assert(!SameSurface(granted, shrunk_desktop));

  auto swapped_device = granted;
  swapped_device.device = L"\\\\.\\DISPLAY2";
  assert(!SameSurface(granted, swapped_device));

  auto moved_source = granted;
  moved_source.source.left = 1920;
  assert(!SameSurface(granted, moved_source));
}

// Raises the kill intent from INSIDE an Apply, deterministically simulating a
// hotkey/Stop racing into the middle of a draining batch.
class InterruptingAdapter : public RecordingAdapter {
 public:
  explicit InterruptingAdapter(RemoteControlPolicy& policy)
      : policy_(policy) {}
  bool Apply(const InputEvent& event,
             const DesktopRect& source,
             const DesktopRect& desktop) override {
    const bool ok = RecordingAdapter::Apply(event, source, desktop);
    if (applied.size() == 1) policy_.RequestInterrupt();
    return ok;
  }

 private:
  RemoteControlPolicy& policy_;
};

// M10 audit 2026-07-27: a revoke serializing behind an in-flight batch let
// every remaining event of a 64-event batch inject after the kill hotkey.
// The lock-free interrupt bounds injection to the event already in flight,
// and the release obligations of applied events survive into the revoke.
void KillIntentInterruptsAnInFlightBatch() {
  RemoteControlPolicy policy;
  FakeSecrets secrets;
  const auto grant = Activate(policy, secrets);
  InterruptingAdapter adapter(policy);
  assert(policy.Queue(Binding(),
                      Input(grant, 1,
                            {KeyEvent{65, true}, KeyEvent{65, false},
                             KeyEvent{66, true}}),
                      1000) == QueueDecision::kQueued);
  assert(policy.DrainOne(adapter) == DrainDecision::kApplied);
  assert(adapter.applied.size() == 1);

  // The truncation itself must park the applied prefix's held keys — the
  // batch's own key-up was in the discarded tail and is gone forever, and a
  // revoke does not always follow. Proven WITHOUT revoking: the every-tick
  // ReleasePending retry alone must get the key back up.
  RecordingAdapter retry;
  policy.ReleasePending(retry);
  assert(retry.released_keys == std::vector<std::uint16_t>{65});

  RecordingAdapter release;
  policy.Revoke(release);
  assert(release.released_keys.empty());  // already released above

  // A kill intent raised BEFORE the drain starts must also block it — this is
  // the case the snapshot-per-drain version could not see, and it is exactly
  // the one Stop() produces when it loses the race for the runtime mutex.
  RemoteControlPolicy pre;
  FakeSecrets pre_secrets;
  const auto pre_grant = Activate(pre, pre_secrets);
  RecordingAdapter pre_adapter;
  assert(pre.Queue(Binding(),
                   Input(pre_grant, 1, {KeyEvent{65, true}, KeyEvent{66, true}}),
                   1000) == QueueDecision::kQueued);
  pre.RequestInterrupt();
  assert(pre.DrainOne(pre_adapter) == DrainDecision::kStale);
  assert(pre_adapter.applied.empty());  // not one event reached the adapter

  // A pending intent also stops new work being accepted, so a truncated grant
  // cannot idle as a zombie whose per-drain queue clear prevents the
  // queue-full revoke from ever firing.
  RemoteControlPolicy zombie;
  FakeSecrets zombie_secrets;
  const auto zombie_grant = Activate(zombie, zombie_secrets);
  zombie.RequestInterrupt();
  assert(zombie.Queue(Binding(), Input(zombie_grant, 1, {KeyEvent{65, true}}),
                      1000) == QueueDecision::kInactive);

  // No intent raised → the whole batch drains; the check is not a throttle.
  RemoteControlPolicy plain_policy;
  FakeSecrets plain_secrets;
  const auto plain_grant = Activate(plain_policy, plain_secrets);
  RecordingAdapter plain;
  assert(plain_policy.Queue(
             Binding(),
             Input(plain_grant, 1, {KeyEvent{65, true}, KeyEvent{65, false}}),
             1000) == QueueDecision::kQueued);
  assert(plain_policy.DrainOne(plain) == DrainDecision::kApplied);
  assert(plain.applied.size() == 2);
}

void DelayedScopedInterruptCannotPoisonAReplacementGrant() {
  RemoteControlPolicy policy;
  FakeSecrets secrets;
  RecordingAdapter adapter;
  const auto first = Activate(policy, secrets);
  const auto delayed_stop = policy.CaptureInterrupt(first.epoch);
  assert(delayed_stop);
  assert(policy.Revoke(adapter));
  const auto replacement = Activate(policy, secrets);
  assert(replacement.epoch != first.epoch);
  // Deterministic barrier: capture A, replace with B, then deliver A's stop.
  delayed_stop();
  assert(!policy.InterruptPending());
  assert(policy.Queue(Binding(), Input(replacement, 1, {MoveEvent{0, 0}}),
                      1000) == QueueDecision::kQueued);
  assert(policy.DrainOne(adapter) == DrainDecision::kApplied);
  assert(adapter.applied.size() == 1);
  const auto current_stop = policy.CaptureInterrupt(replacement.epoch);
  assert(current_stop);
  current_stop();
  delayed_stop();  // A must also be unable to clear B's pending stop.
  assert(policy.InterruptPending());
  assert(policy.Queue(Binding(), Input(replacement, 2, {MoveEvent{1, 1}}),
                      1001) == QueueDecision::kInactive);
}

}  // namespace


void SuppressedPacketsConsumeSequenceWithoutQueueing() {
  FakeSecrets secrets;
  RecordingAdapter adapter;
  RemoteControlPolicy policy;
  const auto grant = Activate(
      policy, secrets,
      static_cast<Capabilities>(CapabilityBit(Capability::kMouse) |
                                CapabilityBit(Capability::kKeyboard)));
  assert(policy.Queue(Binding(), Input(grant, 1, {KeyEvent{65, true}}), 1) ==
         QueueDecision::kQueued);
  assert(policy.DrainOne(adapter) == DrainDecision::kApplied);
  assert(policy.Suspend());
  const auto applied = adapter.applied.size();

  // Every gate still runs; failures do not advance the sequence.
  auto stale_token = Input(grant, 2, {MoveEvent{0, 0}});
  stale_token.token[0] ^= 0x01;
  auto wrong_epoch = Input(grant, 2, {MoveEvent{0, 0}});
  ++wrong_epoch.epoch;
  auto wrong_source = Input(grant, 2, {MoveEvent{0, 0}});
  ++wrong_source.source_revision;
  SessionBinding wrong_sender = Binding();
  wrong_sender.call_id = "call-b";
  assert(policy.ConsumeSuppressed(Binding(), stale_token, 2) ==
         QueueDecision::kTokenMismatch);
  assert(policy.ConsumeSuppressed(Binding(), wrong_epoch, 2) ==
         QueueDecision::kEpochMismatch);
  assert(policy.ConsumeSuppressed(Binding(), wrong_source, 2) ==
         QueueDecision::kSourceMismatch);
  assert(policy.ConsumeSuppressed(wrong_sender,
                                  Input(grant, 2, {MoveEvent{0, 0}}), 2) ==
         QueueDecision::kBindingMismatch);
  assert(policy.ConsumeSuppressed(Binding(), Input(grant, 2, {TextEvent{"x"}}),
                                  2) == QueueDecision::kCapabilityMismatch);

  assert(policy.ConsumeSuppressed(Binding(), Input(grant, 2, {MoveEvent{1, 1}}),
                                  2) == QueueDecision::kConsumedSuppressed);
  assert(policy.queued_batches() == 0);
  assert(policy.ConsumeSuppressed(Binding(), Input(grant, 2, {MoveEvent{1, 1}}),
                                  2) == QueueDecision::kDuplicateOrOutOfOrder);
  // The ordinary path still refuses while suspended.
  assert(policy.Queue(Binding(), Input(grant, 3, {MoveEvent{1, 1}}), 3) ==
         QueueDecision::kSuspended);
  assert(policy.Resume(adapter));
  // Sequence 3 is admitted (no gap); sequence 2 was never queued or applied.
  assert(policy.Queue(Binding(), Input(grant, 3, {MoveEvent{0.2, 0.2}}), 3) ==
         QueueDecision::kQueued);
  assert(policy.DrainOne(adapter) == DrainDecision::kApplied);
  assert(policy.DrainOne(adapter) == DrainDecision::kEmpty);
  assert(adapter.applied.size() == applied + 1);

  // A genuine gap still revokes while suspended.
  assert(policy.Suspend());
  assert(policy.ConsumeSuppressed(Binding(), Input(grant, 5, {MoveEvent{0, 0}}),
                                  4) == QueueDecision::kSequenceGapRevoke);
  assert(!policy.Snapshot().active);
  assert(policy.ConsumeSuppressed(Binding(), Input(grant, 6, {MoveEvent{0, 0}}),
                                  5) == QueueDecision::kInactive);
}

void SuppressedPathIsRateLimitedAndReleasesButtons() {
  {
    // A flood of validly sequenced suppressed packets trips the rate limit.
    FakeSecrets secrets;
    RemoteControlPolicy policy;
    const auto grant = Activate(policy, secrets);
    assert(policy.Suspend());
    for (std::uint64_t sequence = 1; sequence <= 60; ++sequence) {
      assert(policy.ConsumeSuppressed(
                 Binding(), Input(grant, sequence, {MoveEvent{0, 0}}), 5) ==
             QueueDecision::kConsumedSuppressed);
    }
    assert(policy.ConsumeSuppressed(
               Binding(), Input(grant, 61, {MoveEvent{0, 0}}), 5) ==
           QueueDecision::kRateExceededRevoke);
    assert(!policy.Snapshot().active);
  }
  {
    // A mouse button held before the pause is released, not re-pressed.
    FakeSecrets secrets;
    RecordingAdapter adapter;
    RemoteControlPolicy policy;
    const auto grant = Activate(policy, secrets);
    assert(policy.Queue(
               Binding(),
               Input(grant, 1, {ButtonEvent{MouseButton::kLeft, true}}), 1) ==
           QueueDecision::kQueued);
    assert(policy.DrainOne(adapter) == DrainDecision::kApplied);
    const auto applied = adapter.applied.size();
    assert(policy.Suspend());
    assert(policy.ConsumeSuppressed(
               Binding(), Input(grant, 2, {MoveEvent{0, 0}}), 2) ==
           QueueDecision::kConsumedSuppressed);
    assert(policy.Resume(adapter));
    assert(adapter.released_buttons ==
           std::vector<MouseButton>{MouseButton::kLeft});
    assert(policy.Queue(Binding(), Input(grant, 3, {MoveEvent{0.2, 0.2}}), 3) ==
           QueueDecision::kQueued);
    assert(policy.DrainOne(adapter) == DrainDecision::kApplied);
    assert(adapter.applied.size() == applied + 1);
    assert(std::holds_alternative<MoveEvent>(adapter.applied.back()));
  }
}

int main() {
  assert(RemoteTextUtf16Units("abc") == 3);
  assert(RemoteTextUtf16Units("\xf0\x9f\x98\x80") == 2);
  assert(!RemoteTextUtf16Units("\xed\xa0\x80"));
  {
    RemoteControlPolicy policy;
    FakeSecrets secrets;
    const auto grant = Activate(policy, secrets);
    assert(policy.Queue(Binding(), Input(grant, 1, {TextEvent{std::string(129, 'a')}}), 1)
           == QueueDecision::kRateExceededRevoke);
    assert(!policy.Snapshot().active);
  }
  DelayedScopedInterruptCannotPoisonAReplacementGrant();
  MappingHandlesNegativeVirtualOrigins();
  RequestAntiNagIsPerBoundSourceSession();
  GrantTokensAreFreshAndEveryGateFailsClosed();
  CapabilitiesAndQueuePressureFailClosed();
  HeldInputsReleaseOnSuspendResumeRevokeAndRateFailure();
  SuppressedPacketsConsumeSequenceWithoutQueueing();
  SuppressedPathIsRateLimitedAndReleasesButtons();
  RevokeCannotRacePastAnApplyingEvent();
  SurfaceIdentityBindsDeviceAndBothGeometries();
  KillIntentInterruptsAnInFlightBatch();
  ClipboardConsentBindsIdHashBytesAndTimeout();
  ClipboardOfferLifetimeIsBounded();
}
