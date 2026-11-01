#pragma once

#include "remote_control_policy.h"
#include "remote_control_win32_constants.h"

#ifndef NOMINMAX
#define NOMINMAX
#endif
#include <windows.h>

#include <atomic>
#include <cstdint>
#include <functional>
#include <mutex>
#include <optional>
#include <string>
#include <vector>

namespace sybl::remote {

enum class SafetyObservation {
  kSafe,
  kUnsafe,
  kUnknown,
};

class ProcessPrivilegeProbe {
 public:
  virtual ~ProcessPrivilegeProbe() = default;
  virtual SafetyObservation Observe() = 0;
};

enum class RawInputOrigin {
  kPhysical,
  kInjected,
  kUnknown,
};

class InputDesktopProbe {
 public:
  virtual ~InputDesktopProbe() = default;
  virtual SafetyObservation Observe() = 0;
};

class BannerVisibilityProbe {
 public:
  virtual ~BannerVisibilityProbe() = default;
  virtual SafetyObservation Observe() = 0;
};

class KillHotkeyRegistrar {
 public:
  virtual ~KillHotkeyRegistrar() = default;
  virtual bool Register(HWND owner, int id, UINT modifiers, UINT virtual_key) = 0;
  // Returns whether the OS actually released the registration. Win32 hotkeys
  // are thread-affine: a cross-thread UnregisterHotKey fails and leaks, so a
  // false result must keep the cleanup pending instead of being discarded.
  virtual bool Unregister(HWND owner, int id) = 0;
};

class RawInputMonitor {
 public:
  virtual ~RawInputMonitor() = default;
  virtual bool Register(HWND owner) = 0;
  virtual void Unregister() = 0;
  virtual RawInputOrigin Classify(LPARAM raw_input_handle) = 0;
};

class MonotonicClock {
 public:
  virtual ~MonotonicClock() = default;
  virtual std::uint64_t NowMs() = 0;
};

class Win32InputDesktopProbe final : public InputDesktopProbe {
 public:
  SafetyObservation Observe() override;
};

// Remote hosting is supported only in the ordinary medium-integrity band
// without UIAccess. A manually elevated/inherited-high process would otherwise
// let SendInput reach elevated applications, invalidating the advertised UIPI
// boundary even though the executable manifest itself requests no elevation.
SafetyObservation ClassifyProcessPrivilege(DWORD integrity_rid,
                                           bool ui_access);

class Win32ProcessPrivilegeProbe final : public ProcessPrivilegeProbe {
 public:
  SafetyObservation Observe() override;
};

class Win32BannerVisibilityProbe final : public BannerVisibilityProbe {
 public:
  explicit Win32BannerVisibilityProbe(HWND banner = nullptr);
  void SetBanner(HWND banner);
  SafetyObservation Observe() override;

 private:
  HWND banner_ = nullptr;
};

class Win32KillHotkeyRegistrar final : public KillHotkeyRegistrar {
 public:
  bool Register(HWND owner, int id, UINT modifiers, UINT virtual_key) override;
  bool Unregister(HWND owner, int id) override;
};

class Win32RawInputMonitor final : public RawInputMonitor {
 public:
  bool Register(HWND owner) override;
  void Unregister() override;
  RawInputOrigin Classify(LPARAM raw_input_handle) override;

 private:
  HWND owner_ = nullptr;
  bool registered_ = false;
};

class Win32MonotonicClock final : public MonotonicClock {
 public:
  std::uint64_t NowMs() override;
};

enum class RuntimeState {
  kIdle,
  kActive,
  kSuspended,
};

enum class RuntimeReason {
  kNone,
  kProcessPrivilegeUnsafe,
  kProcessPrivilegeUnknown,
  kDesktopUnsafe,
  kDesktopUnknown,
  kBannerHidden,
  kBannerUnknown,
  kPhysicalTakeover,
  kLocalStop,
  kHotkey,
  kCallEnded,
  kSourceChanged,
  kFocusDenied,
  kAppForegroundLost,
  kRateExceeded,
  kQueueOverflow,
  kSequenceGap,
  kInputFailure,
  kTransportFailure,
  kProtectedSurface,
  kLeaseExpired,
  kShutdown,
};

enum class RuntimeEventType {
  kActivated,
  kSuspended,
  kResumed,
  kRevoked,
  kHotkeyRegistered,
  kHotkeyUnavailable,
  kPhysicalTakeover,
  kClipboardPrompt,
  kClipboardReady,
  kClipboardRejected,
};

struct RuntimeEvent {
  RuntimeEventType type = RuntimeEventType::kRevoked;
  RuntimeState state = RuntimeState::kIdle;
  RuntimeReason reason = RuntimeReason::kNone;
  int hotkey_id = 0;
  UINT hotkey_modifiers = 0;
  UINT hotkey_virtual_key = 0;
  std::string clipboard_id;
  SessionBinding binding;
  std::uint64_t epoch = 0;
};

struct RuntimeAuthorityStatus {
  ActiveGrant grant;
  bool release_complete = true;
  bool input_allowed = false;
};

using RuntimeEventCallback = std::function<void(const RuntimeEvent&)>;

struct HotkeyBinding {
  int id = 0x5342;
  UINT modifiers = MOD_CONTROL | MOD_ALT | MOD_NOREPEAT;
  UINT virtual_key = VK_ESCAPE;
};

struct RuntimeConfig {
  PolicyLimits policy;
  HotkeyBinding preferred_hotkey;
  HotkeyBinding fallback_hotkey{0x5343, MOD_CONTROL | MOD_SHIFT | MOD_NOREPEAT,
                                VK_ESCAPE};
  std::uint64_t physical_takeover_ms = 600;
};

enum class RuntimeQueueDecision {
  kQueued,
  kSuppressedByPhysicalHost,
  kSuspended,
  kRejected,
  kRevoked,
};

class RemoteControlRuntime {
 public:
  RemoteControlRuntime(InputAdapter& input,
                       SecretSource& secrets,
                       HashProvider& hashes,
                       ProcessPrivilegeProbe& process_privilege,
                       InputDesktopProbe& desktop,
                       BannerVisibilityProbe& banner,
                       KillHotkeyRegistrar& hotkey,
                       RawInputMonitor& raw_input,
                       MonotonicClock& clock,
                       RuntimeConfig config = {});
  ~RemoteControlRuntime();

  RemoteControlRuntime(const RemoteControlRuntime&) = delete;
  RemoteControlRuntime& operator=(const RemoteControlRuntime&) = delete;

  void SetEventCallback(RuntimeEventCallback callback);

  // Local controllee action only. The banner must already exist and be
  // observably visible. The returned token/epoch are convenience facts to send
  // in a grant message; authority remains in this native runtime.
  std::optional<ActiveGrant> Activate(HWND owner,
                                      const SessionBinding& binding,
                                      const DesktopRect& source,
                                      const DesktopRect& virtual_desktop,
                                      Capabilities capabilities,
                                      bool initial_co_control = false);

  bool Stop(RuntimeReason reason = RuntimeReason::kLocalStop);
  // Block intent is published before waiting for a running adapter call.
  // True confirms that all release obligations are complete. Unblock never
  // restores a grant and fails while release obligations remain.
  bool SetInputBlocked(
      bool blocked,
      std::uint64_t deadline_ms = 0,
      std::uint64_t expected_block_generation = 0);
  void BlockInput();
  bool InputAllowed() const;
  bool PermissionExpired() const;
  std::uint64_t block_generation() const;
  RuntimeAuthorityStatus AuthorityStatus() const;
  // Lifecycle callbacks that captured an older call/source must not revoke a
  // replacement grant. The binding comparison and revoke are one runtime-lock
  // transaction.
  bool StopIfBinding(
      const SessionBinding& expected,
      std::uint64_t expected_epoch,
      RuntimeReason reason = RuntimeReason::kLocalStop);
  void PollSafety();

  // Settle any parked hotkey unregistration. MUST be called on the owner/UI
  // thread (Win32 hotkeys are thread-affine). PollSafety already does this on
  // its timer; Shutdown calls it explicitly because it then kills that timer.
  void DrainHotkeyCleanup();

  RequestDecision ObserveRequest(const SessionBinding& binding);
  RuntimeQueueDecision QueueInput(const SessionBinding& authenticated_sender,
                                  const InputMessage& message);
  DrainDecision DrainOne();

  bool HandleWindowMessage(UINT message, WPARAM wparam, LPARAM lparam);
  RawInputOrigin HandleRawInput(LPARAM raw_input_handle);
  // Local controllee choice only. In co-control, physical host input remains
  // effective but does not suppress the authenticated remote stream. Turning
  // co-control off restores the normal recent-host-input suppression window.
  // Returns false when no live grant owns the setting.
  bool SetCoControl(bool enabled);
  // Binding-aware form for host coordination that may race call/source
  // replacement. The comparison and mode change are atomic.
  bool SetCoControlIfBinding(const SessionBinding& expected, bool enabled);

  void BindClipboardCall(const SessionBinding& binding, Capabilities capabilities);
  ClipboardDecision ObserveClipboardOffer(const SessionBinding& sender,
                                           const ClipboardOfferMessage& offer);
  ClipboardDecision ReceiveClipboardData(const SessionBinding& sender,
                                          const ClipboardDataMessage& data);
  std::optional<std::string> PreviewClipboard(const std::string& id);
  std::optional<AcceptedClipboard> AcceptClipboard(const std::string& id);
  ClipboardDecision RejectClipboard(const std::string& id);

  RuntimeState state() const;
  RuntimeReason suspend_reason() const;
  ActiveGrant grant() const;
  bool hotkey_available() const;
  std::uint64_t host_priority_until_ms() const;
  bool co_control() const;

 private:
  class SafetyCheckedAdapter;
  class DesktopReleaseAdapter;

  struct Dispatch {
    RuntimeEventCallback callback;
    std::vector<RuntimeEvent> events;
  };

  RuntimeReason ObserveSafetyLocked();
  void PollSafetyLocked(std::vector<RuntimeEvent>& events);
  void RevokeLocked(RuntimeReason reason, std::vector<RuntimeEvent>& events);
  void CleanupRegistrationsLocked();
  void DrainHotkeyCleanupLocked();
  bool HotkeyIdStillOwedLocked(int id) const;
  bool HostHasPriorityLocked(std::uint64_t now_ms) const;
  void PhysicalTakeoverLocked(std::uint64_t now_ms,
                              std::vector<RuntimeEvent>& events);
  RuntimeEvent MakeEvent(RuntimeEventType type,
                         RuntimeReason reason = RuntimeReason::kNone) const;
  Dispatch FinishLocked(std::vector<RuntimeEvent> events);
  static void DispatchEvents(Dispatch dispatch);

  InputAdapter& input_;
  SecretSource& secrets_;
  HashProvider& hashes_;
  ProcessPrivilegeProbe& process_privilege_;
  InputDesktopProbe& desktop_;
  BannerVisibilityProbe& banner_;
  KillHotkeyRegistrar& hotkey_;
  RawInputMonitor& raw_input_;
  MonotonicClock& clock_;
  const RuntimeConfig config_;

  mutable std::mutex mutex_;
  RemoteControlPolicy policy_;
  // ClipboardConsentPolicy is intentionally lock-free internally. Every
  // Bind/Offer/Data/Preview/Accept/Reject/EndCall access is made while mutex_
  // is held, including the hash-provider call; the concurrency test proves a
  // local accept cannot overtake network data verification.
  ClipboardConsentPolicy clipboard_;
  RuntimeEventCallback callback_;
  RuntimeState state_ = RuntimeState::kIdle;
  RuntimeReason suspend_reason_ = RuntimeReason::kNone;
  HWND owner_ = nullptr;
  std::optional<HotkeyBinding> registered_hotkey_;
  // Hotkeys whose unregistration is owed to the UI thread. Cleanup can run on
  // the daemon thread (call-end revoke), where UnregisterHotKey fails and would
  // leak the registration for the process lifetime; instead the ids are parked
  // here and drained by PollSafety / the next Activate on the owner thread,
  // retrying until the OS confirms each release. A LIST, not one slot: a drain
  // is allowed to fail, so a second session can park a second id while the
  // first is still owed — a single slot silently dropped the older obligation
  // and leaked that hotkey combo for the process lifetime.
  std::vector<std::pair<HWND, int>> pending_hotkey_cleanup_;
  bool raw_input_registered_ = false;
  std::uint64_t host_priority_until_ms_ = 0;
  bool co_control_ = false;
  std::atomic<std::uint64_t> active_epoch_{0};
  std::atomic<bool> input_blocked_{true};
  std::atomic<std::uint64_t> permission_deadline_ms_{0};
  std::atomic<std::uint64_t> block_generation_{1};
  std::atomic<std::uint64_t> allowed_generation_{0};
  std::shared_ptr<const SessionBinding> active_binding_identity_;
};

}  // namespace sybl::remote
