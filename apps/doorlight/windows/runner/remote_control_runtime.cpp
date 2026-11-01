#include "remote_control_runtime.h"

#include <dwmapi.h>

#include <algorithm>
#include <limits>
#include <memory>
#include <string>
#include <utility>

namespace sybl::remote {
namespace {

std::optional<std::wstring> DesktopName(HDESK desktop) {
  if (!desktop) return std::nullopt;
  DWORD bytes = 0;
  SetLastError(ERROR_SUCCESS);
  GetUserObjectInformationW(desktop, UOI_NAME, nullptr, 0, &bytes);
  if (bytes < sizeof(wchar_t) || bytes > 4096) return std::nullopt;
  std::vector<wchar_t> value(bytes / sizeof(wchar_t), L'\0');
  if (!GetUserObjectInformationW(desktop, UOI_NAME, value.data(), bytes, &bytes))
    return std::nullopt;
  return std::wstring(value.data());
}

std::uint64_t SaturatingAdd(std::uint64_t left, std::uint64_t right) {
  if (right > std::numeric_limits<std::uint64_t>::max() - left)
    return std::numeric_limits<std::uint64_t>::max();
  return left + right;
}

RuntimeReason SafetyReason(SafetyObservation process_privilege,
                           SafetyObservation desktop,
                           SafetyObservation banner) {
  if (process_privilege == SafetyObservation::kUnsafe)
    return RuntimeReason::kProcessPrivilegeUnsafe;
  if (process_privilege == SafetyObservation::kUnknown)
    return RuntimeReason::kProcessPrivilegeUnknown;
  if (desktop == SafetyObservation::kUnsafe)
    return RuntimeReason::kDesktopUnsafe;
  if (desktop == SafetyObservation::kUnknown)
    return RuntimeReason::kDesktopUnknown;
  if (banner == SafetyObservation::kUnsafe)
    return RuntimeReason::kBannerHidden;
  if (banner == SafetyObservation::kUnknown)
    return RuntimeReason::kBannerUnknown;
  return RuntimeReason::kNone;
}

}  // namespace

SafetyObservation ClassifyProcessPrivilege(DWORD integrity_rid,
                                           bool ui_access) {
  if (ui_access ||
      integrity_rid < SECURITY_MANDATORY_MEDIUM_RID ||
      integrity_rid >= SECURITY_MANDATORY_HIGH_RID) {
    return SafetyObservation::kUnsafe;
  }
  return SafetyObservation::kSafe;
}

SafetyObservation Win32ProcessPrivilegeProbe::Observe() {
  HANDLE token = nullptr;
  if (!OpenProcessToken(GetCurrentProcess(), TOKEN_QUERY, &token))
    return SafetyObservation::kUnknown;

  DWORD bytes = 0;
  SetLastError(ERROR_SUCCESS);
  GetTokenInformation(token, TokenIntegrityLevel, nullptr, 0, &bytes);
  if (GetLastError() != ERROR_INSUFFICIENT_BUFFER ||
      bytes < sizeof(TOKEN_MANDATORY_LABEL) || bytes > 4096) {
    CloseHandle(token);
    return SafetyObservation::kUnknown;
  }
  std::vector<BYTE> storage(bytes);
  if (!GetTokenInformation(token, TokenIntegrityLevel, storage.data(), bytes,
                           &bytes)) {
    CloseHandle(token);
    return SafetyObservation::kUnknown;
  }
  const auto* label =
      reinterpret_cast<const TOKEN_MANDATORY_LABEL*>(storage.data());
  const auto sid = label->Label.Sid;
  if (!sid || !IsValidSid(sid)) {
    CloseHandle(token);
    return SafetyObservation::kUnknown;
  }
  const auto count = GetSidSubAuthorityCount(sid);
  if (!count || *count == 0) {
    CloseHandle(token);
    return SafetyObservation::kUnknown;
  }
  const auto rid = GetSidSubAuthority(sid, *count - 1);
  if (!rid) {
    CloseHandle(token);
    return SafetyObservation::kUnknown;
  }

  DWORD ui_access = 0;
  DWORD ui_access_bytes = 0;
  if (!GetTokenInformation(token, TokenUIAccess, &ui_access,
                           sizeof(ui_access), &ui_access_bytes) ||
      ui_access_bytes != sizeof(ui_access)) {
    CloseHandle(token);
    return SafetyObservation::kUnknown;
  }
  CloseHandle(token);
  return ClassifyProcessPrivilege(*rid, ui_access != 0);
}

SafetyObservation Win32InputDesktopProbe::Observe() {
  const auto thread = GetThreadDesktop(GetCurrentThreadId());
  if (!thread) return SafetyObservation::kUnknown;
  const auto input =
      OpenInputDesktop(0, FALSE, DESKTOP_READOBJECTS);
  if (!input) return SafetyObservation::kUnknown;
  const auto thread_name = DesktopName(thread);
  const auto input_name = DesktopName(input);
  CloseDesktop(input);
  if (!thread_name || !input_name) return SafetyObservation::kUnknown;
  return _wcsicmp(thread_name->c_str(), input_name->c_str()) == 0
      ? SafetyObservation::kSafe
      : SafetyObservation::kUnsafe;
}

Win32BannerVisibilityProbe::Win32BannerVisibilityProbe(HWND banner)
    : banner_(banner) {}

void Win32BannerVisibilityProbe::SetBanner(HWND banner) {
  banner_ = banner;
}

SafetyObservation Win32BannerVisibilityProbe::Observe() {
  if (!banner_ || !IsWindow(banner_)) return SafetyObservation::kUnknown;
  if (!IsWindowVisible(banner_) || IsIconic(banner_))
    return SafetyObservation::kUnsafe;
  DWORD cloaked = 0;
  if (FAILED(DwmGetWindowAttribute(banner_, DWMWA_CLOAKED, &cloaked,
                                   sizeof(cloaked)))) {
    return SafetyObservation::kUnknown;
  }
  if (cloaked != 0) return SafetyObservation::kUnsafe;
  SetLastError(ERROR_SUCCESS);
  const auto extended_style = GetWindowLongPtrW(banner_, GWL_EXSTYLE);
  if (extended_style == 0 && GetLastError() != ERROR_SUCCESS)
    return SafetyObservation::kUnknown;
  if ((extended_style & WS_EX_TOPMOST) == 0) return SafetyObservation::kUnsafe;

  RECT rect{};
  if (!GetWindowRect(banner_, &rect) || rect.right <= rect.left ||
      rect.bottom <= rect.top) {
    return SafetyObservation::kUnknown;
  }
  const POINT center{
      rect.left + (rect.right - rect.left) / 2,
      rect.top + (rect.bottom - rect.top) / 2,
  };
  const auto hit = WindowFromPoint(center);
  if (!hit) return SafetyObservation::kUnsafe;
  return GetAncestor(hit, GA_ROOT) == banner_ ? SafetyObservation::kSafe
                                              : SafetyObservation::kUnsafe;
}

bool Win32KillHotkeyRegistrar::Register(HWND owner,
                                        int id,
                                        UINT modifiers,
                                        UINT virtual_key) {
  return owner && RegisterHotKey(owner, id, modifiers, virtual_key) != FALSE;
}

bool Win32KillHotkeyRegistrar::Unregister(HWND owner, int id) {
  return owner && UnregisterHotKey(owner, id) != FALSE;
}

bool Win32RawInputMonitor::Register(HWND owner) {
  if (!owner || registered_) return false;
  RAWINPUTDEVICE devices[2]{};
  devices[0].usUsagePage = 0x01;
  devices[0].usUsage = 0x02;  // mouse
  devices[0].dwFlags = RIDEV_INPUTSINK;
  devices[0].hwndTarget = owner;
  devices[1].usUsagePage = 0x01;
  devices[1].usUsage = 0x06;  // keyboard
  devices[1].dwFlags = RIDEV_INPUTSINK;
  devices[1].hwndTarget = owner;
  if (!RegisterRawInputDevices(devices, 2, sizeof(RAWINPUTDEVICE))) return false;
  owner_ = owner;
  registered_ = true;
  return true;
}

void Win32RawInputMonitor::Unregister() {
  if (!registered_) return;
  RAWINPUTDEVICE devices[2]{};
  devices[0].usUsagePage = 0x01;
  devices[0].usUsage = 0x02;
  devices[0].dwFlags = RIDEV_REMOVE;
  devices[1].usUsagePage = 0x01;
  devices[1].usUsage = 0x06;
  devices[1].dwFlags = RIDEV_REMOVE;
  RegisterRawInputDevices(devices, 2, sizeof(RAWINPUTDEVICE));
  owner_ = nullptr;
  registered_ = false;
}

RawInputOrigin Win32RawInputMonitor::Classify(LPARAM raw_input_handle) {
  if (!registered_ || raw_input_handle == 0) return RawInputOrigin::kUnknown;
  UINT bytes = 0;
  if (GetRawInputData(reinterpret_cast<HRAWINPUT>(raw_input_handle),
                      RID_INPUT, nullptr, &bytes,
                      sizeof(RAWINPUTHEADER)) != 0 ||
      bytes < sizeof(RAWINPUTHEADER) || bytes > 4096) {
    return RawInputOrigin::kUnknown;
  }
  std::vector<BYTE> storage(bytes);
  if (GetRawInputData(reinterpret_cast<HRAWINPUT>(raw_input_handle),
                      RID_INPUT, storage.data(), &bytes,
                      sizeof(RAWINPUTHEADER)) != bytes) {
    return RawInputOrigin::kUnknown;
  }
  const auto* raw = reinterpret_cast<const RAWINPUT*>(storage.data());
  ULONG_PTR extra = 0;
  if (raw->header.dwType == RIM_TYPEMOUSE) {
    extra = raw->data.mouse.ulExtraInformation;
  } else if (raw->header.dwType == RIM_TYPEKEYBOARD) {
    extra = raw->data.keyboard.ExtraInformation;
  } else {
    return RawInputOrigin::kUnknown;
  }
  if (extra == kRemoteInputExtraInfo) return RawInputOrigin::kInjected;
  return raw->header.hDevice ? RawInputOrigin::kPhysical
                             : RawInputOrigin::kUnknown;
}

std::uint64_t Win32MonotonicClock::NowMs() {
  return GetTickCount64();
}

class RemoteControlRuntime::SafetyCheckedAdapter final : public InputAdapter {
 public:
  SafetyCheckedAdapter(InputAdapter& inner,
                       ProcessPrivilegeProbe& process_privilege,
                       InputDesktopProbe& desktop,
                       BannerVisibilityProbe& banner,
                       std::function<bool()> allowed)
      : inner_(inner),
        process_privilege_(process_privilege),
        desktop_(desktop),
        banner_(banner),
        allowed_(std::move(allowed)) {}

  bool Apply(const InputEvent& event,
             const DesktopRect& source,
             const DesktopRect& virtual_desktop) override {
    const auto permitted = [this]() {
      if (!allowed_()) {
        failure_reason = RuntimeReason::kProtectedSurface;
        return false;
      }
      failure_reason = SafetyReason(process_privilege_.Observe(),
                                     desktop_.Observe(), banner_.Observe());
      return failure_reason == RuntimeReason::kNone;
    };
    if (!inner_.ApplyGuarded(event, source, virtual_desktop, permitted)) {
      if (failure_reason == RuntimeReason::kNone)
        failure_reason = RuntimeReason::kInputFailure;
      return false;
    }
    return true;
  }

  bool ReleaseKey(std::uint16_t virtual_key) override {
    return desktop_.Observe() == SafetyObservation::kSafe &&
        inner_.ReleaseKey(virtual_key);
  }

  bool ReleaseButton(MouseButton button) override {
    return desktop_.Observe() == SafetyObservation::kSafe &&
        inner_.ReleaseButton(button);
  }

  bool ReleasePending() override {
    return desktop_.Observe() == SafetyObservation::kSafe &&
        inner_.ReleasePending();
  }

  RuntimeReason failure_reason = RuntimeReason::kNone;

 private:
  InputAdapter& inner_;
  ProcessPrivilegeProbe& process_privilege_;
  InputDesktopProbe& desktop_;
  BannerVisibilityProbe& banner_;
  std::function<bool()> allowed_;
};

class RemoteControlRuntime::DesktopReleaseAdapter final : public InputAdapter {
 public:
  DesktopReleaseAdapter(InputAdapter& inner, InputDesktopProbe& desktop)
      : inner_(inner), desktop_(desktop) {}

  bool Apply(const InputEvent&,
             const DesktopRect&,
             const DesktopRect&) override {
    return false;
  }
  bool ReleaseKey(std::uint16_t virtual_key) override {
    return desktop_.Observe() == SafetyObservation::kSafe &&
        inner_.ReleaseKey(virtual_key);
  }
  bool ReleaseButton(MouseButton button) override {
    return desktop_.Observe() == SafetyObservation::kSafe &&
        inner_.ReleaseButton(button);
  }

  bool ReleasePending() override {
    return desktop_.Observe() == SafetyObservation::kSafe &&
        inner_.ReleasePending();
  }

 private:
  InputAdapter& inner_;
  InputDesktopProbe& desktop_;
};

RemoteControlRuntime::RemoteControlRuntime(
    InputAdapter& input,
    SecretSource& secrets,
    HashProvider& hashes,
    ProcessPrivilegeProbe& process_privilege,
    InputDesktopProbe& desktop,
    BannerVisibilityProbe& banner,
    KillHotkeyRegistrar& hotkey,
    RawInputMonitor& raw_input,
    MonotonicClock& clock,
    RuntimeConfig config)
    : input_(input),
      secrets_(secrets),
      hashes_(hashes),
      process_privilege_(process_privilege),
      desktop_(desktop),
      banner_(banner),
      hotkey_(hotkey),
      raw_input_(raw_input),
      clock_(clock),
      config_(config),
      policy_(config.policy),
      clipboard_(config.policy) {}

RemoteControlRuntime::~RemoteControlRuntime() {
  std::lock_guard<std::mutex> lock(mutex_);
  DesktopReleaseAdapter release(input_, desktop_);
  policy_.Revoke(release);
  active_epoch_.store(0, std::memory_order_release);
  clipboard_.EndCall();
  CleanupRegistrationsLocked();
}

void RemoteControlRuntime::SetEventCallback(RuntimeEventCallback callback) {
  std::lock_guard<std::mutex> lock(mutex_);
  callback_ = std::move(callback);
}

RemoteControlRuntime::Dispatch RemoteControlRuntime::FinishLocked(
    std::vector<RuntimeEvent> events) {
  return Dispatch{callback_, std::move(events)};
}

void RemoteControlRuntime::DispatchEvents(Dispatch dispatch) {
  if (!dispatch.callback) return;
  for (const auto& event : dispatch.events) dispatch.callback(event);
}

RuntimeEvent RemoteControlRuntime::MakeEvent(RuntimeEventType type,
                                             RuntimeReason reason) const {
  RuntimeEvent event;
  event.type = type;
  event.state = state_;
  event.reason = reason;
  const auto grant = policy_.Snapshot();
  event.binding = grant.binding;
  event.epoch = grant.epoch;
  if (registered_hotkey_) {
    event.hotkey_id = registered_hotkey_->id;
    event.hotkey_modifiers = registered_hotkey_->modifiers;
    event.hotkey_virtual_key = registered_hotkey_->virtual_key;
  }
  return event;
}

std::optional<ActiveGrant> RemoteControlRuntime::Activate(
    HWND owner,
    const SessionBinding& binding,
    const DesktopRect& source,
    const DesktopRect& virtual_desktop,
    Capabilities capabilities,
    bool initial_co_control) {
  std::optional<ActiveGrant> result;
  Dispatch dispatch;
  {
    std::lock_guard<std::mutex> lock(mutex_);
    std::vector<RuntimeEvent> events;
    DesktopReleaseAdapter release(input_, desktop_);
    if (state_ == RuntimeState::kIdle) policy_.ReleasePending(release);
    if (!InputAllowed() ||
        state_ != RuntimeState::kIdle || !owner ||
        ObserveSafetyLocked() != RuntimeReason::kNone ||
        !raw_input_.Register(owner)) {
      dispatch = FinishLocked({});
    } else {
      owner_ = owner;
      raw_input_registered_ = true;
      // Activate runs on the UI thread: settle any parked unregistration
      // first so a leftover registration cannot collide with the fresh one.
      // Skip any id still owed. On a correct OS this is redundant — it holds
      // the registration, so Register would just fail and we degrade honestly.
      // It is kept as bookkeeping hygiene: an id that is simultaneously
      // "registered by us" and "owed to the drain" would have the next
      // PollSafety tick unregister the live session's own hotkey. Belt and
      // braces, with no failing-mutation evidence behind it.
      DrainHotkeyCleanupLocked();
      if (!HotkeyIdStillOwedLocked(config_.preferred_hotkey.id) &&
          hotkey_.Register(owner, config_.preferred_hotkey.id,
                           config_.preferred_hotkey.modifiers,
                           config_.preferred_hotkey.virtual_key)) {
        registered_hotkey_ = config_.preferred_hotkey;
      } else if (!HotkeyIdStillOwedLocked(config_.fallback_hotkey.id) &&
                 hotkey_.Register(owner, config_.fallback_hotkey.id,
                                  config_.fallback_hotkey.modifiers,
                                  config_.fallback_hotkey.virtual_key)) {
        registered_hotkey_ = config_.fallback_hotkey;
      }
      result = policy_.Activate(binding, source, virtual_desktop,
                                capabilities, secrets_);
      if (!result) {
        CleanupRegistrationsLocked();
        DrainHotkeyCleanupLocked();  // same thread registered it — safe now
      } else {
        state_ = RuntimeState::kActive;
        std::atomic_store_explicit(
            &active_binding_identity_,
            std::make_shared<const SessionBinding>(binding),
            std::memory_order_release);
        active_epoch_.store(result->epoch, std::memory_order_release);
        suspend_reason_ = RuntimeReason::kNone;
        host_priority_until_ms_ = 0;
        co_control_ = initial_co_control;
        clipboard_.BindCall(binding, capabilities);
        events.push_back(MakeEvent(RuntimeEventType::kActivated));
        events.push_back(MakeEvent(
            registered_hotkey_ ? RuntimeEventType::kHotkeyRegistered
                               : RuntimeEventType::kHotkeyUnavailable));
      }
      dispatch = FinishLocked(std::move(events));
    }
  }
  DispatchEvents(std::move(dispatch));
  return result;
}

void RemoteControlRuntime::CleanupRegistrationsLocked() {
  if (registered_hotkey_) {
    // Never unregister inline: this cleanup runs on the daemon thread for the
    // ordinary call-end revoke, where the thread-affine UnregisterHotKey
    // fails and silently leaks the registration — after which no later
    // session can register a kill hotkey (M10 audit 2026-07-27, verified on
    // this OS). Park it; the UI thread drains it in PollSafety / Activate.
    pending_hotkey_cleanup_.emplace_back(owner_, registered_hotkey_->id);
    registered_hotkey_.reset();
  }
  if (raw_input_registered_) {
    raw_input_.Unregister();
    raw_input_registered_ = false;
  }
  owner_ = nullptr;
}

void RemoteControlRuntime::DrainHotkeyCleanupLocked() {
  for (auto it = pending_hotkey_cleanup_.begin();
       it != pending_hotkey_cleanup_.end();) {
    // A dead owner window is retried on every tick for the process lifetime.
    // Accepted: two failing syscalls per 100 ms, only after an already-rare
    // refused unregister. An IsWindow() short-circuit would put an untestable
    // Win32 call inside the one path the unit tests do cover.
    if (hotkey_.Unregister(it->first, it->second))
      it = pending_hotkey_cleanup_.erase(it);
    else
      ++it;  // still owed — retry on the next owner-thread pass
  }
}

void RemoteControlRuntime::DrainHotkeyCleanup() {
  std::lock_guard<std::mutex> lock(mutex_);
  DrainHotkeyCleanupLocked();
}

bool RemoteControlRuntime::HotkeyIdStillOwedLocked(int id) const {
  return std::any_of(pending_hotkey_cleanup_.begin(),
                     pending_hotkey_cleanup_.end(),
                     [id](const auto& owed) { return owed.second == id; });
}

void RemoteControlRuntime::RevokeLocked(RuntimeReason reason,
                                        std::vector<RuntimeEvent>& events) {
  const auto previous_binding = std::atomic_load_explicit(
      &active_binding_identity_, std::memory_order_acquire);
  const auto previous_epoch = active_epoch_.load(std::memory_order_acquire);
  DesktopReleaseAdapter release(input_, desktop_);
  policy_.Revoke(release);
  std::atomic_store_explicit(
      &active_binding_identity_, std::shared_ptr<const SessionBinding>{},
      std::memory_order_release);
  active_epoch_.store(0, std::memory_order_release);
  clipboard_.EndCall();
  state_ = RuntimeState::kIdle;
  suspend_reason_ = RuntimeReason::kNone;
  host_priority_until_ms_ = 0;
  co_control_ = false;
  CleanupRegistrationsLocked();
  auto event = MakeEvent(RuntimeEventType::kRevoked, reason);
  event.binding = previous_binding ? *previous_binding : SessionBinding{};
  event.epoch = previous_epoch;
  events.push_back(std::move(event));
}

bool RemoteControlRuntime::Stop(RuntimeReason reason) {
  // Raise the kill intent BEFORE the lock: if the daemon thread is mid-batch
  // it holds mutex_, and without this every remaining event of that batch
  // would inject before the revoke could run (M10 audit 2026-07-27).
  policy_.RequestInterrupt();
  bool stopped = false;
  Dispatch dispatch;
  {
    std::lock_guard<std::mutex> lock(mutex_);
    std::vector<RuntimeEvent> events;
    if (state_ != RuntimeState::kIdle) {
      RevokeLocked(reason, events);
    } else {
      // Revoke, not ReleasePending: it does the same releases AND acknowledges
      // the intent raised above. Leaving an intent unanswered here would make
      // the next session's ability to drain depend on Activate reaching its
      // acknowledge line — a fragile coupling for a kill switch.
      DesktopReleaseAdapter release(input_, desktop_);
      policy_.Revoke(release);
      CleanupRegistrationsLocked();
    }
    stopped = !policy_.Snapshot().active && policy_.release_complete();
    dispatch = FinishLocked(std::move(events));
  }
  DispatchEvents(std::move(dispatch));
  return stopped;
}

void RemoteControlRuntime::BlockInput() {
  block_generation_.fetch_add(1, std::memory_order_acq_rel);
  input_blocked_.store(true, std::memory_order_release);
  policy_.RequestInterrupt();
}

bool RemoteControlRuntime::SetInputBlocked(bool blocked,
                                           std::uint64_t deadline_ms,
                                           std::uint64_t generation) {
  if (blocked) {
    BlockInput();
    return Stop(RuntimeReason::kProtectedSurface);
  }
  std::lock_guard<std::mutex> lock(mutex_);
  if (generation == 0 ||
      generation != block_generation_.load(std::memory_order_acquire))
    return false;
  if (deadline_ms <= clock_.NowMs()) return false;
  if (InputAllowed()) {
    permission_deadline_ms_.store(deadline_ms, std::memory_order_release);
    return true;
  }
  if (!input_blocked_.load(std::memory_order_acquire)) return false;
  DesktopReleaseAdapter release(input_, desktop_);
  policy_.ReleasePending(release);
  if (state_ != RuntimeState::kIdle || !policy_.release_complete()) return false;
  // Revoke answers any block interrupt, including initial permission setup.
  policy_.Revoke(release);
  permission_deadline_ms_.store(deadline_ms, std::memory_order_release);
  allowed_generation_.store(generation, std::memory_order_release);
  input_blocked_.store(false, std::memory_order_release);
  return true;
}

bool RemoteControlRuntime::InputAllowed() const {
  return !input_blocked_.load(std::memory_order_acquire) &&
      allowed_generation_.load(std::memory_order_acquire) ==
          block_generation_.load(std::memory_order_acquire) &&
      clock_.NowMs() < permission_deadline_ms_.load(std::memory_order_acquire) &&
      !policy_.InterruptPending();
}

bool RemoteControlRuntime::PermissionExpired() const {
  return !input_blocked_.load(std::memory_order_acquire) &&
      clock_.NowMs() >= permission_deadline_ms_.load(std::memory_order_acquire);
}

std::uint64_t RemoteControlRuntime::block_generation() const {
  return block_generation_.load(std::memory_order_acquire);
}

RuntimeAuthorityStatus RemoteControlRuntime::AuthorityStatus() const {
  std::lock_guard<std::mutex> lock(mutex_);
  return {policy_.Snapshot(), policy_.release_complete(), InputAllowed()};
}

bool RemoteControlRuntime::StopIfBinding(const SessionBinding& expected,
                                         std::uint64_t expected_epoch,
                                         RuntimeReason reason) {
  // Publish both identity and epoch lock-free when a grant activates. That
  // lets a binding-scoped teardown interrupt an in-flight batch before it can
  // acquire the runtime mutex, without allowing a stale stop to affect a
  // successor session.
  const auto active_binding = std::atomic_load_explicit(
      &active_binding_identity_, std::memory_order_acquire);
  if (!active_binding || !(*active_binding == expected) ||
      expected_epoch == 0 ||
      active_epoch_.load(std::memory_order_acquire) != expected_epoch) {
    return false;
  }
  // Retain this grant's interrupt target. Replacement between this capture
  // and publication cannot redirect the old callback to the new grant.
  const auto interrupt = policy_.CaptureInterrupt(expected_epoch);
  if (!interrupt) return false;
  interrupt();
  bool stopped = false;
  Dispatch dispatch;
  {
    std::lock_guard<std::mutex> lock(mutex_);
    std::vector<RuntimeEvent> events;
    const auto live = policy_.Snapshot();
    if (state_ != RuntimeState::kIdle && live.active &&
        live.binding == expected && live.epoch == expected_epoch) {
      RevokeLocked(reason, events);
      stopped = true;
    } else if (state_ == RuntimeState::kIdle) {
      DesktopReleaseAdapter release(input_, desktop_);
      policy_.Revoke(release);
    }
    dispatch = FinishLocked(std::move(events));
  }
  DispatchEvents(std::move(dispatch));
  return stopped;
}

RuntimeReason RemoteControlRuntime::ObserveSafetyLocked() {
  if (input_blocked_.load(std::memory_order_acquire) ||
      allowed_generation_.load(std::memory_order_acquire) !=
          block_generation_.load(std::memory_order_acquire))
    return RuntimeReason::kProtectedSurface;
  if (PermissionExpired()) return RuntimeReason::kLeaseExpired;
  return SafetyReason(process_privilege_.Observe(), desktop_.Observe(),
                      banner_.Observe());
}

bool RemoteControlRuntime::HostHasPriorityLocked(std::uint64_t now_ms) const {
  return !co_control_ && host_priority_until_ms_ != 0 &&
      now_ms < host_priority_until_ms_;
}

void RemoteControlRuntime::PollSafetyLocked(std::vector<RuntimeEvent>& events) {
  DesktopReleaseAdapter release(input_, desktop_);
  // Retry retained release obligations on EVERY tick, in every state. A
  // session suspended for one reason (hidden banner, host priority) can
  // outlive the secure-desktop moment that retained its keys, and the old
  // kIdle-only retry left VK_CONTROL physically latched for as long as the
  // other reason persisted (M10 audit 2026-07-27). The adapter refuses on the
  // wrong desktop, so an early retry is inert until the release is possible.
  policy_.ReleasePending(release);
  if (state_ == RuntimeState::kIdle) {
    return;
  }
  const auto now = clock_.NowMs();
  const auto safety = ObserveSafetyLocked();
  if (safety == RuntimeReason::kProtectedSurface ||
      safety == RuntimeReason::kLeaseExpired ||
      safety == RuntimeReason::kProcessPrivilegeUnsafe ||
      safety == RuntimeReason::kProcessPrivilegeUnknown) {
    RevokeLocked(safety, events);
    return;
  }
  const bool physical_suppression = HostHasPriorityLocked(now);
  if (safety != RuntimeReason::kNone || physical_suppression) {
    const auto reason = safety != RuntimeReason::kNone
        ? safety
        : RuntimeReason::kPhysicalTakeover;
    if (state_ == RuntimeState::kActive && policy_.Suspend()) {
      state_ = RuntimeState::kSuspended;
      suspend_reason_ = reason;
      // Suspending must not leave a remote key or button held on the normal
      // input desktop. Resume performs the pending releases; immediately
      // suspend again so no new remote event can pass the gate.
      if (policy_.Resume(release)) policy_.Suspend();
      events.push_back(MakeEvent(RuntimeEventType::kSuspended, reason));
    }
    return;
  }
  if (state_ == RuntimeState::kSuspended && policy_.Resume(release)) {
    state_ = RuntimeState::kActive;
    suspend_reason_ = RuntimeReason::kNone;
    events.push_back(MakeEvent(RuntimeEventType::kResumed));
  }
}

void RemoteControlRuntime::PollSafety() {
  Dispatch dispatch;
  {
    std::lock_guard<std::mutex> lock(mutex_);
    std::vector<RuntimeEvent> events;
    // This public wrapper is only driven by the host's UI-thread safety
    // timer, which makes it the drain point for thread-affine hotkey
    // cleanup. (PollSafetyLocked itself also runs on the daemon thread via
    // QueueInput — the drain must not live there.)
    DrainHotkeyCleanupLocked();
    PollSafetyLocked(events);
    dispatch = FinishLocked(std::move(events));
  }
  DispatchEvents(std::move(dispatch));
}

RequestDecision RemoteControlRuntime::ObserveRequest(
    const SessionBinding& binding) {
  std::lock_guard<std::mutex> lock(mutex_);
  return policy_.ObserveRequest(binding, clock_.NowMs());
}

RuntimeQueueDecision RemoteControlRuntime::QueueInput(
    const SessionBinding& authenticated_sender,
    const InputMessage& message) {
  RuntimeQueueDecision result = RuntimeQueueDecision::kRejected;
  Dispatch dispatch;
  {
    std::lock_guard<std::mutex> lock(mutex_);
    std::vector<RuntimeEvent> events;
    PollSafetyLocked(events);
    const auto now = clock_.NowMs();
    const bool physical_host = HostHasPriorityLocked(now);
    if (physical_host || state_ == RuntimeState::kSuspended) {
      // Suppressed input is dropped, never queued. It still passes every
      // policy gate and consumes its sequence number, so the first packet
      // after resume is contiguous rather than a forged-looking gap.
      result = physical_host ? RuntimeQueueDecision::kSuppressedByPhysicalHost
                             : RuntimeQueueDecision::kSuspended;
      if (state_ == RuntimeState::kActive ||
          state_ == RuntimeState::kSuspended) {
        const auto consumed =
            policy_.ConsumeSuppressed(authenticated_sender, message, now);
        if (consumed == QueueDecision::kRateExceededRevoke) {
          RevokeLocked(RuntimeReason::kRateExceeded, events);
          result = RuntimeQueueDecision::kRevoked;
        } else if (consumed == QueueDecision::kSequenceGapRevoke) {
          RevokeLocked(RuntimeReason::kSequenceGap, events);
          result = RuntimeQueueDecision::kRevoked;
        }
      }
    } else if (state_ == RuntimeState::kActive) {
      const auto queued = policy_.Queue(authenticated_sender, message, now);
      if (queued == QueueDecision::kQueued) {
        result = RuntimeQueueDecision::kQueued;
      } else if (queued == QueueDecision::kRateExceededRevoke) {
        RevokeLocked(RuntimeReason::kRateExceeded, events);
        result = RuntimeQueueDecision::kRevoked;
      } else if (queued == QueueDecision::kQueueFullRevoke) {
        RevokeLocked(RuntimeReason::kQueueOverflow, events);
        result = RuntimeQueueDecision::kRevoked;
      } else if (queued == QueueDecision::kSequenceGapRevoke) {
        RevokeLocked(RuntimeReason::kSequenceGap, events);
        result = RuntimeQueueDecision::kRevoked;
      } else if (queued == QueueDecision::kSuspended) {
        result = RuntimeQueueDecision::kSuspended;
      }
    }
    dispatch = FinishLocked(std::move(events));
  }
  DispatchEvents(std::move(dispatch));
  return result;
}

DrainDecision RemoteControlRuntime::DrainOne() {
  DrainDecision result = DrainDecision::kEmpty;
  Dispatch dispatch;
  {
    std::lock_guard<std::mutex> lock(mutex_);
    std::vector<RuntimeEvent> events;
    PollSafetyLocked(events);
    if (state_ == RuntimeState::kActive &&
        !HostHasPriorityLocked(clock_.NowMs())) {
      SafetyCheckedAdapter guarded(input_, process_privilege_, desktop_,
                                   banner_, [this] { return InputAllowed(); });
      result = policy_.DrainOne(guarded);
      if (result == DrainDecision::kAdapterFailureRevoke) {
        RevokeLocked(PermissionExpired() ? RuntimeReason::kLeaseExpired
                         : guarded.failure_reason == RuntimeReason::kNone
                         ? RuntimeReason::kInputFailure
                         : guarded.failure_reason,
                     events);
      }
    }
    dispatch = FinishLocked(std::move(events));
  }
  DispatchEvents(std::move(dispatch));
  return result;
}

bool RemoteControlRuntime::HandleWindowMessage(UINT message,
                                               WPARAM wparam,
                                               LPARAM) {
  // WM_HOTKEY carrying EITHER of our two ids is a local stop: only our own
  // registrations deliver these ids to this window. Raise and revoke must
  // cover exactly the same set — an earlier version raised for both but
  // revoked only for the currently-registered one, so pressing the panic key
  // while a leaked registration owned the other id raised an intent nothing
  // ever answered: input died silently and the session never ended.
  const bool ours = message == WM_HOTKEY &&
      (static_cast<int>(wparam) == config_.preferred_hotkey.id ||
       static_cast<int>(wparam) == config_.fallback_hotkey.id);
  if (!ours) return false;
  // Pre-lock: waiting for mutex_ would let an in-flight batch finish injecting.
  policy_.RequestInterrupt();
  Dispatch dispatch;
  {
    std::lock_guard<std::mutex> lock(mutex_);
    std::vector<RuntimeEvent> events;
    if (state_ != RuntimeState::kIdle) {
      RevokeLocked(RuntimeReason::kHotkey, events);
    } else {
      // Nothing to tear down, but the intent still has to be answered.
      DesktopReleaseAdapter release(input_, desktop_);
      policy_.Revoke(release);
    }
    dispatch = FinishLocked(std::move(events));
  }
  DispatchEvents(std::move(dispatch));
  return true;
}

void RemoteControlRuntime::PhysicalTakeoverLocked(
    std::uint64_t now_ms,
    std::vector<RuntimeEvent>& events) {
  if (state_ == RuntimeState::kIdle) return;
  host_priority_until_ms_ =
      SaturatingAdd(now_ms, config_.physical_takeover_ms);
  // Co-control is a real arbitration mode: local hardware continues to work,
  // while the independently authenticated remote stream remains live. The
  // banner, kill switch, secure-desktop checks, and every grant/input gate are
  // unchanged. Only host-priority mode turns local activity into suppression.
  if (co_control_) return;
  if (state_ == RuntimeState::kActive && policy_.Suspend()) {
    state_ = RuntimeState::kSuspended;
    suspend_reason_ = RuntimeReason::kPhysicalTakeover;
    // Host takeover happens on the interactive desktop, so release remote
    // holds immediately. Re-suspend after the release to keep new input
    // suppressed for the full takeover window.
    DesktopReleaseAdapter release(input_, desktop_);
    if (policy_.Resume(release)) policy_.Suspend();
    events.push_back(
        MakeEvent(RuntimeEventType::kSuspended,
                  RuntimeReason::kPhysicalTakeover));
  }
  events.push_back(
      MakeEvent(RuntimeEventType::kPhysicalTakeover,
                RuntimeReason::kPhysicalTakeover));
}

RawInputOrigin RemoteControlRuntime::HandleRawInput(LPARAM raw_input_handle) {
  RawInputOrigin origin = RawInputOrigin::kUnknown;
  Dispatch dispatch;
  {
    std::lock_guard<std::mutex> lock(mutex_);
    std::vector<RuntimeEvent> events;
    origin = raw_input_.Classify(raw_input_handle);
    if (origin != RawInputOrigin::kInjected)
      PhysicalTakeoverLocked(clock_.NowMs(), events);
    dispatch = FinishLocked(std::move(events));
  }
  DispatchEvents(std::move(dispatch));
  return origin;
}

bool RemoteControlRuntime::SetCoControl(bool enabled) {
  bool applied = false;
  Dispatch dispatch;
  {
    std::lock_guard<std::mutex> lock(mutex_);
    std::vector<RuntimeEvent> events;
    if (state_ != RuntimeState::kIdle) {
      co_control_ = enabled;
      // Re-evaluate immediately. Enabling co-control resumes a session that
      // was paused only by recent physical input; disabling it during that
      // same window immediately restores host-priority suppression.
      PollSafetyLocked(events);
      applied = true;
    }
    dispatch = FinishLocked(std::move(events));
  }
  DispatchEvents(std::move(dispatch));
  return applied;
}

bool RemoteControlRuntime::SetCoControlIfBinding(
    const SessionBinding& expected,
    bool enabled) {
  bool applied = false;
  Dispatch dispatch;
  {
    std::lock_guard<std::mutex> lock(mutex_);
    std::vector<RuntimeEvent> events;
    const auto live = policy_.Snapshot();
    if (state_ != RuntimeState::kIdle && live.active &&
        live.binding == expected) {
      co_control_ = enabled;
      PollSafetyLocked(events);
      applied = true;
    }
    dispatch = FinishLocked(std::move(events));
  }
  DispatchEvents(std::move(dispatch));
  return applied;
}

void RemoteControlRuntime::BindClipboardCall(const SessionBinding& binding,
                                             Capabilities capabilities) {
  std::lock_guard<std::mutex> lock(mutex_);
  clipboard_.BindCall(binding, capabilities);
}

ClipboardDecision RemoteControlRuntime::ObserveClipboardOffer(
    const SessionBinding& sender,
    const ClipboardOfferMessage& offer) {
  ClipboardDecision result;
  Dispatch dispatch;
  {
    std::lock_guard<std::mutex> lock(mutex_);
    std::vector<RuntimeEvent> events;
    result = clipboard_.ObserveOffer(sender, offer, clock_.NowMs());
    if (result == ClipboardDecision::kPrompt) {
      auto event = MakeEvent(RuntimeEventType::kClipboardPrompt);
      event.clipboard_id = offer.id;
      events.push_back(std::move(event));
    }
    dispatch = FinishLocked(std::move(events));
  }
  DispatchEvents(std::move(dispatch));
  return result;
}

ClipboardDecision RemoteControlRuntime::ReceiveClipboardData(
    const SessionBinding& sender,
    const ClipboardDataMessage& data) {
  ClipboardDecision result;
  Dispatch dispatch;
  {
    std::lock_guard<std::mutex> lock(mutex_);
    std::vector<RuntimeEvent> events;
    result = clipboard_.ReceiveData(sender, data, clock_.NowMs(), hashes_);
    if (result == ClipboardDecision::kDuplicate) return result;
    auto event = MakeEvent(result == ClipboardDecision::kReady
                               ? RuntimeEventType::kClipboardReady
                               : RuntimeEventType::kClipboardRejected);
    event.clipboard_id = data.id;
    events.push_back(std::move(event));
    dispatch = FinishLocked(std::move(events));
  }
  DispatchEvents(std::move(dispatch));
  return result;
}

std::optional<std::string> RemoteControlRuntime::PreviewClipboard(
    const std::string& id) {
  std::lock_guard<std::mutex> lock(mutex_);
  return clipboard_.Preview(id, clock_.NowMs());
}

std::optional<AcceptedClipboard> RemoteControlRuntime::AcceptClipboard(
    const std::string& id) {
  std::lock_guard<std::mutex> lock(mutex_);
  return clipboard_.Accept(id, clock_.NowMs());
}

ClipboardDecision RemoteControlRuntime::RejectClipboard(
    const std::string& id) {
  ClipboardDecision result;
  Dispatch dispatch;
  {
    std::lock_guard<std::mutex> lock(mutex_);
    std::vector<RuntimeEvent> events;
    result = clipboard_.Reject(id);
    if (result == ClipboardDecision::kRejected) {
      auto event = MakeEvent(RuntimeEventType::kClipboardRejected);
      event.clipboard_id = id;
      events.push_back(std::move(event));
    }
    dispatch = FinishLocked(std::move(events));
  }
  DispatchEvents(std::move(dispatch));
  return result;
}

RuntimeState RemoteControlRuntime::state() const {
  std::lock_guard<std::mutex> lock(mutex_);
  return state_;
}

RuntimeReason RemoteControlRuntime::suspend_reason() const {
  std::lock_guard<std::mutex> lock(mutex_);
  return suspend_reason_;
}

ActiveGrant RemoteControlRuntime::grant() const {
  std::lock_guard<std::mutex> lock(mutex_);
  return policy_.Snapshot();
}

bool RemoteControlRuntime::hotkey_available() const {
  std::lock_guard<std::mutex> lock(mutex_);
  return registered_hotkey_.has_value();
}

std::uint64_t RemoteControlRuntime::host_priority_until_ms() const {
  std::lock_guard<std::mutex> lock(mutex_);
  return host_priority_until_ms_;
}

bool RemoteControlRuntime::co_control() const {
  std::lock_guard<std::mutex> lock(mutex_);
  return co_control_;
}

}  // namespace sybl::remote
