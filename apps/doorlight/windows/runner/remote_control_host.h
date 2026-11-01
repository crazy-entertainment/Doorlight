#pragma once

#include "remote_control_activation.h"
#include "remote_control_grants.h"
#include "remote_control_ice.h"
#include "remote_control_runtime.h"
#include "win32_input_adapter.h"

#include <windows.h>

#include <functional>
#include <map>
#include <memory>
#include <mutex>
#include <optional>
#include <string>

namespace sybl::remote {

struct InboundControlEnvelope {
  std::string account_id;
  std::string call_id;
  std::string controller_account;
  std::string controller_device;
  std::string payload;
  std::string source_uri;
  std::uint64_t source_revision = 0;
  int source_width = 0;
  int source_height = 0;
  LocalIcePath local_ice_path = LocalIcePath::kUnknown;
  bool local_lan_proven = false;
  std::string local_jami_id;
};

using HostEventSink = std::function<void(
    const std::string&, const std::map<std::string, std::string>&)>;
using ControlPacketSender =
    std::function<bool(const std::string& call_id, const std::string& packet)>;
using HostAuthorityVerifier =
    std::function<bool(const InboundControlEnvelope& envelope)>;

enum class LocalControlResult {
  kApplied,
  kStale,
  kUnavailable,
  kUnsupported,
};

struct HostAuthorityStatus {
  std::uint64_t channel_epoch = 0;
  std::uint64_t surface_revision = 0;
  std::uint64_t host_generation = 0;
  std::uint64_t revoked_through = 0;
  bool blocked = true;
  bool release_complete = true;
  // active includes a suspended grant; revoking means releases remain owed.
  std::string state = "inactive";
};

// Tests replace only OS services. The production host, runtime, policy, wire
// parsing, and consent transaction remain the same.
struct HostDependencies {
  InputAdapter* input = nullptr;
  SecretSource* secrets = nullptr;
  HashProvider* hashes = nullptr;
  ProcessPrivilegeProbe* process_privilege = nullptr;
  InputDesktopProbe* desktop = nullptr;
  BannerVisibilityProbe* banner = nullptr;
  KillHotkeyRegistrar* hotkey = nullptr;
  RawInputMonitor* raw_input = nullptr;
  MonotonicClock* clock = nullptr;
  PersistentGrantStore* grants = nullptr;
  Win32InputAdapter::CursorPositionQuery cursor_position;
  std::function<std::optional<ResolvedSurface>(
      const InboundControlEnvelope&)> resolve_surface;
  std::function<void(RuntimeState, RuntimeReason, const std::string&,
                     std::optional<DesktopRect>)> show_banner;
  std::function<std::string(const InboundControlEnvelope&)> peer_name;
};

// Windows controllee host. Network input only enters through OnControlMessage;
// grant creation is exclusively exposed through the local action methods.
class RemoteControlHost {
  friend struct RemoteControlHostTestAccess;
 public:
  RemoteControlHost(HWND owner,
                    ControlPacketSender sender,
                    HostEventSink events,
                    HostAuthorityVerifier authority = {},
                    HostDependencies dependencies = {});
  ~RemoteControlHost();

  RemoteControlHost(const RemoteControlHost&) = delete;
  RemoteControlHost& operator=(const RemoteControlHost&) = delete;

  void OnControlMessage(InboundControlEnvelope envelope);
  void OnCallEnded(const std::string& call_id);
  bool OnTrustReduced(const std::string& account_id,
                      const std::string& local_jami_id,
                      const std::string& controller_account);
  void OnSourceChanged(const std::string& call_id,
                       std::uint64_t source_revision,
                       bool screen_active);

  LocalControlResult AllowOnce(const std::string& call_id,
                               const std::string& controller_account,
                               const std::string& controller_device,
                               std::uint64_t source_revision,
                               std::uint64_t host_generation);
  LocalControlResult AllowDevice(const std::string& call_id,
                                 const std::string& controller_account,
                                 const std::string& controller_device,
                                 std::uint64_t source_revision,
                                 std::uint64_t host_generation);
  bool ForgetDevice(const std::string& local_account,
                    const std::string& controller_account,
                    const std::string& controller_device);
  LocalControlResult Deny(const std::string& call_id,
                          const std::string& controller_account,
                          const std::string& controller_device,
                          std::uint64_t source_revision,
                          std::uint64_t host_generation);
  bool Stop();
  bool StopGeneration(std::uint64_t generation);
  HostAuthorityStatus ResetAuthorityChannel(bool connected);
  HostAuthorityStatus SetProtectedSurface(std::uint64_t channel_epoch,
                                          std::uint64_t surface_revision,
                                          bool blocked);
  HostAuthorityStatus AuthorityStatus() const;
  LocalControlResult SetCoControl(bool enabled);
  LocalControlResult AcceptClipboard(const std::string& id,
                                     std::uint64_t prompt_generation);
  LocalControlResult RejectClipboard(const std::string& id,
                                     std::uint64_t prompt_generation);
  // The expected binding and host generation are the session the caller
  // captured before it read the clipboard; any difference from the live session
  // is stale, never retargeted.
  LocalControlResult SendClipboard(const std::string& utf8,
                                   const std::string& call_id,
                                   const std::string& controller_account,
                                   const std::string& controller_device,
                                   std::uint64_t source_revision,
                                   std::uint64_t host_generation);

  bool HandleWindowMessage(UINT message, WPARAM wparam, LPARAM lparam);
  void PollSafety();
  void ReplayPendingEvents();
  void Shutdown();
  bool OwnsCall(const std::string& call_id) const;
  void RejectBusy(const std::string& call_id);

 private:
  class Banner;
  class CursorOverlay;

  struct PendingRequest {
    InboundControlEnvelope envelope;
    Capabilities capabilities = 0;
    std::uint64_t received_ms = 0;
    std::uint64_t generation = 0;
    std::string identity_color;
  };
  struct PendingClipboard {
    InboundControlEnvelope envelope;
    std::string id;
    std::string preview;
    std::size_t bytes = 0;
    std::uint64_t generation = 0;
  };
  struct OutgoingClipboard {
    std::string call_id;
    std::uint64_t sent_ms = 0;
  };

  static constexpr std::uint64_t kPromptTimeoutMs = 20000;
  static constexpr std::uint64_t kOwnerUnavailableGraceMs = 3000;
  static constexpr std::uint64_t kClipboardResponseTimeoutMs = 20000;

  SessionBinding BindingFor(const InboundControlEnvelope& envelope) const;
  bool PendingMatchesLocked(const PendingRequest& pending,
                            const std::string& call_id,
                            const std::string& controller_account,
                            const std::string& controller_device,
                            std::uint64_t source_revision) const;
  std::optional<ResolvedSurface> ResolveSurface(
      const InboundControlEnvelope& envelope) const;
  bool InputSurfaceCurrent(const DesktopRect& source,
                           const DesktopRect& virtual_desktop) const;
  void HandleRequest(const InboundControlEnvelope& envelope,
                     const RequestMessage& request);
  void HandleInput(const InboundControlEnvelope& envelope,
                   const InputMessage& input);
  void HandleClipboardOffer(const InboundControlEnvelope& envelope,
                            const ClipboardOfferMessage& offer);
  void HandleClipboardData(const InboundControlEnvelope& envelope,
                           const ClipboardDataMessage& data);
  void HandleClipboardResponse(const InboundControlEnvelope& envelope,
                               const std::string& id,
                               bool accepted);
  void HandleRuntimeEvent(const RuntimeEvent& event);
  void RefreshPendingPathProof(
      const InboundControlEnvelope& envelope);
  void EmitRequest(const PendingRequest& request) const;
  void EmitClipboardRequest(const PendingClipboard& request) const;
  bool Send(const std::string& call_id, const Message& message);
  void Emit(const std::string& type,
            std::map<std::string, std::string> data) const;
  void RequestBannerSync();
  void ShowBanner(RuntimeState state, RuntimeReason reason,
                  const std::string& controller,
                  std::optional<DesktopRect> source);
  void EmitAuthority() const;
  void RevokeAuthority(RuntimeReason reason);
  bool AuthorityValid(const InboundControlEnvelope& envelope) const;
  HostAuthorityStatus AuthorityStatusLocked() const;
  void SyncBanner();
  void SyncCursor();
  void ExpirePrompt();
  void ExpireOutgoingClipboards();
  bool WriteClipboardText(const std::string& utf8) const;
  static const char* ReasonName(RuntimeReason reason);

  HWND owner_ = nullptr;
  ControlPacketSender sender_;
  HostEventSink events_;
  HostAuthorityVerifier authority_;
  HostDependencies dependencies_;

  Win32InputAdapter input_;
  Win32Crypto crypto_;
  Win32ProcessPrivilegeProbe process_privilege_;
  Win32InputDesktopProbe desktop_;
  Win32KillHotkeyRegistrar hotkey_;
  Win32RawInputMonitor raw_input_;
  Win32MonotonicClock default_clock_;
  MonotonicClock& clock_;
  Win32GrantBlobStorage grant_storage_;
  Win32GrantDpapiProtector grant_protector_;
  PersistentGrantStore default_grants_;
  PersistentGrantStore& grants_;
  SecretSource& secrets_;
  HashProvider& hashes_;
  std::unique_ptr<Banner> banner_;
  std::unique_ptr<CursorOverlay> cursor_overlay_;
  std::unique_ptr<RemoteControlRuntime> runtime_;

  mutable std::mutex mutex_;
  // Serializes manual arbitration reconciliation with final grant
  // publication. Never acquire it while holding mutex_; the order is
  // arbitration_mutex_ -> mutex_ -> (release mutex_) -> runtime.
  std::mutex arbitration_mutex_;
  // Channel state changes and final publication share this lane. Never hold
  // mutex_ while waiting for it or while revoking the callback-owning runtime.
  std::mutex authority_mutex_;
  mutable std::mutex surface_mutex_;
  std::uint64_t authority_change_ = 0;
  bool requested_blocked_ = true;
  std::atomic<bool> input_blocked_{true};
  std::atomic<bool> channel_connected_{false};
  std::atomic<std::uint64_t> channel_epoch_{0};
  std::atomic<std::uint64_t> surface_revision_{0};
  std::uint64_t revoked_through_ = 0;
  std::optional<PendingRequest> pending_;
  std::optional<PendingClipboard> pending_clipboard_;
  std::optional<InboundControlEnvelope> active_;
  // The FULL surface identity as granted (source + virtual desktop + device
  // name), not just the source rect: PollSafety and every mouse submission
  // must detect a moved virtual desktop or a byte-identical device swap.
  std::optional<ResolvedSurface> active_source_;
  struct InputSurfaceProof {
    InboundControlEnvelope envelope;
    ResolvedSurface surface;
  };
  // Published only with the final native grant. The input thread can verify
  // mapping without host-mutex acquisition while it holds the runtime mutex.
  std::shared_ptr<const InputSurfaceProof> input_surface_proof_;
  std::string active_identity_color_;
  std::optional<POINT> cursor_point_;
  std::map<std::string, OutgoingClipboard> outgoing_clipboards_;
  bool shutdown_ = false;
  bool desired_co_control_ = false;
  std::uint64_t owner_unavailable_since_ms_ = 0;
  std::uint64_t next_pending_generation_ = 1;
  std::uint64_t next_clipboard_generation_ = 1;
  std::uint64_t active_host_generation_ = 0;
  std::uint64_t active_runtime_epoch_ = 0;
  ConsentActivation activation_;
};

}  // namespace sybl::remote
