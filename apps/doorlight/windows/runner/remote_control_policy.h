#pragma once

#include "remote_control_protocol.h"

#include <atomic>
#include <cstdint>
#include <deque>
#include <functional>
#include <map>
#include <memory>
#include <mutex>
#include <optional>
#include <set>
#include <string>
#include <string_view>
#include <vector>

namespace sybl::remote {

struct SessionBinding {
  std::string call_id;
  std::string controller_account;
  std::string controller_device;
  std::uint64_t source_revision = 0;

  bool operator==(const SessionBinding& other) const;
};

struct DesktopRect {
  std::int32_t left = 0;
  std::int32_t top = 0;
  std::int32_t width = 0;
  std::int32_t height = 0;
};

// The full identity of the shared surface as granted: the source monitor's
// geometry, the virtual-desktop geometry (the coordinate space absolute
// injection is encoded against), and the monitor's durable Windows device
// name. A change in ANY component invalidates the grant's mapping — two
// same-size monitors can trade rects (only the device name catches it), and
// removing another monitor can move the virtual desktop while the shared
// source rect stays byte-identical, silently redirecting every absolute
// coordinate onto a display that was never shared (M10 audit 2026-07-27).
struct ResolvedSurface {
  DesktopRect source;
  DesktopRect virtual_desktop;
  std::wstring device;
};

bool SameSurface(const ResolvedSurface& a, const ResolvedSurface& b);

struct AbsolutePoint {
  std::int32_t x = 0;
  std::int32_t y = 0;
};

std::optional<AbsolutePoint> MapToVirtualDesktop(const MoveEvent& event,
                                                 const DesktopRect& source,
                                                 const DesktopRect& virtual_desktop);

class SecretSource {
 public:
  virtual ~SecretSource() = default;
  virtual std::optional<std::string> GenerateHex(std::size_t bytes) = 0;
};

class HashProvider {
 public:
  virtual ~HashProvider() = default;
  virtual std::optional<std::string> Sha256Hex(std::string_view bytes) = 0;
};

class InputAdapter {
 public:
  virtual ~InputAdapter() = default;
  virtual bool Apply(const InputEvent& event,
                     const DesktopRect& source,
                     const DesktopRect& virtual_desktop) = 0;
  // Production adapters that expand an event must recheck this permission at
  // each OS operation. Release methods remain available for revoke cleanup.
  virtual bool ApplyGuarded(const InputEvent& event,
                            const DesktopRect& source,
                            const DesktopRect& virtual_desktop,
                            const std::function<bool()>& allowed) {
    return allowed && allowed() && Apply(event, source, virtual_desktop);
  }
  virtual bool ReleaseKey(std::uint16_t virtual_key) = 0;
  virtual bool ReleaseButton(MouseButton button) = 0;
  virtual bool ReleasePending() { return true; }
};

struct PolicyLimits {
  std::size_t max_queued_batches = 8;
  std::size_t max_messages_per_second = 60;
  std::size_t max_events_per_second = 256;
  std::uint64_t request_dedupe_ms = 3000;
  std::size_t max_requests_per_call = 3;
  std::uint64_t clipboard_timeout_ms = 20000;
};

enum class RequestDecision {
  kPrompt,
  kDuplicate,
  kCapped,
  kInvalid,
};

enum class QueueDecision {
  kQueued,
  // Valid and contiguous, but deliberately not queued (see ConsumeSuppressed).
  kConsumedSuppressed,
  kInactive,
  kSuspended,
  kBindingMismatch,
  kTokenMismatch,
  kEpochMismatch,
  kSourceMismatch,
  kCapabilityMismatch,
  kDuplicateOrOutOfOrder,
  kRateExceededRevoke,
  kQueueFullRevoke,
  kSequenceGapRevoke,
  kInvalid,
};

enum class DrainDecision {
  kApplied,
  kEmpty,
  kStale,
  kAdapterFailureRevoke,
};

struct ActiveGrant {
  bool active = false;
  bool suspended = false;
  SessionBinding binding;
  DesktopRect source;
  DesktopRect virtual_desktop;
  Capabilities capabilities = 0;
  std::string token;
  std::uint64_t epoch = 0;
};

class RemoteControlPolicy {
 public:
  explicit RemoteControlPolicy(PolicyLimits limits = {});

  RequestDecision ObserveRequest(const SessionBinding& binding, std::uint64_t now_ms);

  std::optional<ActiveGrant> Activate(const SessionBinding& binding,
                                      const DesktopRect& source,
                                      const DesktopRect& virtual_desktop,
                                      Capabilities capabilities,
                                      SecretSource& secrets);

  bool Revoke(InputAdapter& adapter);
  bool Suspend();
  bool Resume(InputAdapter& adapter);
  bool ReleasePending(InputAdapter& adapter);

  // Lock-free kill intent. A local stop (kill hotkey, Stop) raises this BEFORE
  // taking any mutex. DrainOne refuses to inject while an intent is
  // unacknowledged — both at entry and between events — so a revoke that
  // serializes behind an in-flight batch cannot let the batch's remaining
  // events reach SendInput, and neither can one that loses the race for the
  // mutex entirely. Only Activate and Revoke acknowledge.
  // Every caller MUST be a path that always ends in an Activate or a Revoke:
  // an intent nobody answers refuses every later drain for the life of the
  // session.
  void RequestInterrupt();
  // A delayed binding-scoped stop can flag only the grant captured here.
  // Capturing and publishing do not wait for an applying batch's mutex.
  std::function<void()> CaptureInterrupt(std::uint64_t expected_epoch) const;
  bool InterruptPending() const;

  QueueDecision Queue(const SessionBinding& authenticated_sender,
                      const InputMessage& message,
                      std::uint64_t now_ms);
  // Runs the same gates as Queue for a packet the runtime deliberately
  // suppresses (physical host priority or a safety suspension). A packet that
  // passes them consumes its sequence number and is dropped: never queued,
  // never applied, never replayed. Anything else behaves exactly as in Queue.
  QueueDecision ConsumeSuppressed(const SessionBinding& authenticated_sender,
                                  const InputMessage& message,
                                  std::uint64_t now_ms);
  DrainDecision DrainOne(InputAdapter& adapter);

  ActiveGrant Snapshot() const;
  std::size_t queued_batches() const;
  std::size_t held_keys() const;
  std::size_t held_buttons() const;
  bool release_complete() const;

 private:
  struct ScopedInterrupt {
    explicit ScopedInterrupt(std::uint64_t value) : epoch(value) {}
    const std::uint64_t epoch;
    std::atomic<bool> requested{false};
  };

  struct QueuedBatch {
    SessionBinding sender;
    InputMessage message;
  };

  bool ValidBinding(const SessionBinding& binding) const;
  bool ValidRect(const DesktopRect& rect) const;
  bool MessageCapabilitiesAllowed(const InputMessage& message) const;
  bool Revalidate(const QueuedBatch& batch) const;
  QueueDecision QueueLocked(const SessionBinding& authenticated_sender,
                            const InputMessage& message,
                            std::uint64_t now_ms,
                            bool suppressed);
  bool ReleaseHeldLocked(InputAdapter& adapter);
  void ClearSessionLocked();
  std::uint64_t NextEpochLocked();
  bool InterruptPendingLocked() const;
  void AcknowledgeInterruptLocked();
  void TruncateForInterruptLocked();

  const PolicyLimits limits_;
  mutable std::mutex mutex_;
  ActiveGrant grant_;
  std::uint64_t next_epoch_ = 0;
  std::string last_token_;
  std::uint64_t last_enqueued_sequence_ = 0;
  std::deque<QueuedBatch> queue_;
  std::set<std::uint16_t> held_keys_;
  std::set<MouseButton> held_buttons_;
  std::set<std::uint16_t> pending_key_releases_;
  std::set<MouseButton> pending_button_releases_;
  bool adapter_release_complete_ = true;

  SessionBinding request_binding_;
  std::uint64_t last_request_ms_ = 0;
  std::size_t request_count_ = 0;

  std::uint64_t rate_window_start_ms_ = 0;
  std::size_t rate_messages_ = 0;
  std::size_t rate_events_ = 0;

  std::atomic<std::uint64_t> interrupt_generation_{0};
  std::atomic<std::uint64_t> interrupt_acknowledged_{0};
  std::shared_ptr<ScopedInterrupt> scoped_interrupt_;
};

enum class ClipboardDecision {
  kPrompt,
  kDuplicate,
  kBusy,
  kInvalid,
  kBindingMismatch,
  kCapabilityMismatch,
  kExpired,
  kHashMismatch,
  kReady,
  kRejected,
};

struct AcceptedClipboard {
  SessionBinding sender;
  std::string id;
  std::string text;
};

class ClipboardConsentPolicy {
 public:
  explicit ClipboardConsentPolicy(PolicyLimits limits = {});

  void BindCall(const SessionBinding& binding, Capabilities capabilities);
  void EndCall();
  ClipboardDecision ObserveOffer(const SessionBinding& sender,
                                 const ClipboardOfferMessage& offer,
                                 std::uint64_t now_ms);
  ClipboardDecision ReceiveData(const SessionBinding& sender,
                                const ClipboardDataMessage& data,
                                std::uint64_t now_ms,
                                HashProvider& hashes);
  std::optional<std::string> Preview(const std::string& id,
                                     std::uint64_t now_ms) const;
  std::optional<AcceptedClipboard> Accept(const std::string& id,
                                          std::uint64_t now_ms);
  ClipboardDecision Reject(const std::string& id);

 private:
  struct Pending {
    SessionBinding sender;
    ClipboardOfferMessage offer;
    std::uint64_t expires_ms = 0;
    std::optional<std::string> received_utf8;
  };

  bool Matches(const SessionBinding& sender) const;

  const PolicyLimits limits_;
  std::optional<SessionBinding> binding_;
  Capabilities capabilities_ = 0;
  std::optional<Pending> pending_;
  // Retained until the grant ends; never evict an ID and revive its consent.
  std::set<std::string> observed_ids_;
};

}  // namespace sybl::remote
