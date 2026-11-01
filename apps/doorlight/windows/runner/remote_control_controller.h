#pragma once

#include "remote_control_policy.h"

#include <cstdint>
#include <functional>
#include <map>
#include <set>
#include <mutex>
#include <optional>
#include <string>
#include <vector>

namespace sybl::remote {

struct ControllerInboundEnvelope {
  std::string account_id;
  std::string call_id;
  std::string peer_account;
  std::string peer_device;
  std::string payload;
};

using ControllerEventSink = std::function<void(
    const std::string&, const std::map<std::string, std::string>&)>;
using ControllerPacketSender =
    std::function<bool(const std::string& call_id, const std::string& packet)>;
using ControllerMonotonicNow = std::function<std::uint64_t()>;
// Called under the session-retirement mutex with native-owned verified text.
using ControllerClipboardWriter = std::function<bool(
    const std::string&, const std::string&, const std::string&,
    const std::string&, const std::string&)>;

// Controller-side protocol authority. Flutter supplies gestures and clipboard
// text, but never receives or supplies the native grant token, epoch, or input
// sequence.
class RemoteControlController {
 public:
  RemoteControlController(ControllerPacketSender sender,
                          ControllerEventSink events,
                          SecretSource& secrets,
                          HashProvider& hashes,
                          ControllerMonotonicNow now,
                          ControllerClipboardWriter clipboard_writer = {});

  bool Request(const std::string& account_id,
               const std::string& call_id,
               const std::string& peer_account,
               std::uint64_t source_revision,
               Capabilities capabilities,
               const std::string& identity_color = "amber");
  bool Input(const std::string& call_id,
             const std::string& peer_account,
             std::uint64_t source_revision,
             std::vector<InputEvent> events);
  bool End(const std::string& call_id,
           const std::string& peer_account,
           std::uint64_t source_revision);
  bool SendClipboard(const std::string& call_id,
                     const std::string& peer_account,
                     std::uint64_t source_revision,
                     const std::string& utf8);
  bool RespondClipboard(const std::string& call_id,
                        const std::string& peer_account,
                        std::uint64_t source_revision,
                        const std::string& id,
                        std::uint64_t prompt_generation,
                        bool accept);

  // Returns true when the packet belongs to the current controller session.
  bool OnControlMessage(const ControllerInboundEnvelope& envelope);
  void OnCallEnded(const std::string& call_id);
  void OnTrustReduced(const std::string& account_id,
                      const std::string& peer_account);
  void Poll();
  void ReplayPendingEvents();
  void Shutdown();
  bool OwnsCall(const std::string& call_id) const;

 private:
  struct Session {
    std::string account_id;
    std::string call_id;
    std::string peer_account;
    std::string peer_device;
    std::uint64_t source_revision = 0;
    Capabilities requested_capabilities = 0;
    Capabilities granted_capabilities = 0;
    std::string token;
    std::uint64_t epoch = 0;
    std::uint64_t sequence = 0;
    std::uint64_t request_started_ms = 0;
    std::uint64_t request_last_sent_ms = 0;
    std::string identity_color;
    bool active = false;
  };

  struct ClipboardOffer {
    std::string id;
    std::string sha256;
    std::uint32_t size = 0;
    std::string text;
    bool ready = false;
    std::uint64_t received_ms = 0;
    std::uint64_t generation = 0;
  };

  struct OutgoingClipboard {
    std::string call_id;
    std::string sha256;
    std::uint64_t sent_ms = 0;
  };

  static constexpr std::uint64_t kClipboardTimeoutMs = 20000;
  static constexpr std::uint64_t kRequestRetryMs = 1000;
  static constexpr std::uint64_t kRequestTimeoutMs = 20000;

  bool MatchesLocked(const std::string& call_id,
                     const std::string& peer_account,
                     std::uint64_t source_revision) const;
  bool AuthenticatedEnvelopeMatchesLocked(
      const ControllerInboundEnvelope& envelope) const;
  bool Send(const std::string& call_id,
            const Message& message,
            WireDirection direction) const;
  bool SendPacket(const std::string& call_id,
                  const std::string& packet) const;
  void EmitState(const Session& session,
                 const std::string& state,
                 const std::string& reason) const;
  void EmitClipboardRequest(const Session& session,
                            const ClipboardOffer& offer) const;
  void PurgeExpiredLocked(
      std::uint64_t now,
      std::vector<std::pair<std::string, std::string>>& timed_out,
      std::optional<Session>& request_timeout);
  void EmitTimeouts(
      const std::vector<std::pair<std::string, std::string>>& timed_out) const;
  void Emit(const std::string& type,
            std::map<std::string, std::string> data) const;
  static const char* DenyReasonName(DenyReason reason);

  ControllerPacketSender sender_;
  ControllerEventSink events_;
  SecretSource& secrets_;
  HashProvider& hashes_;
  ControllerMonotonicNow now_;
  ControllerClipboardWriter clipboard_writer_;

  mutable std::mutex mutex_;
  std::optional<Session> session_;
  std::map<std::string, ClipboardOffer> incoming_clipboards_;
  std::set<std::string> observed_clipboard_ids_;
  std::map<std::string, OutgoingClipboard> outgoing_clipboards_;
  bool shutdown_ = false;
  std::uint64_t next_clipboard_generation_ = 1;
};

}  // namespace sybl::remote
