#include "remote_control_controller.h"
#include "identity_color_wire.h"

#include <algorithm>
#include <string_view>
#include <type_traits>
#include <utility>

namespace sybl::remote {
namespace {

bool IsLowerHex(std::string_view value) {
  return std::all_of(value.begin(), value.end(), [](char c) {
    return (c >= '0' && c <= '9') || (c >= 'a' && c <= 'f');
  });
}

bool ValidPeer(const std::string& value) {
  return value.size() == 40 && IsLowerHex(value);
}

bool ValidCall(const std::string& value) {
  return !value.empty() && value.size() <= 256;
}

bool ValidCapabilities(Capabilities capabilities) {
  constexpr Capabilities kAll =
      CapabilityBit(Capability::kMouse) |
      CapabilityBit(Capability::kKeyboard) |
      CapabilityBit(Capability::kText) |
      CapabilityBit(Capability::kClipboard) |
      CapabilityBit(Capability::kBack) |
      CapabilityBit(Capability::kHome) |
      CapabilityBit(Capability::kRecents);
  return capabilities != 0 && (capabilities & ~kAll) == 0;
}

}  // namespace

RemoteControlController::RemoteControlController(ControllerPacketSender sender,
                                                 ControllerEventSink events,
                                                 SecretSource& secrets,
                                                 HashProvider& hashes,
                                                 ControllerMonotonicNow now,
                                                 ControllerClipboardWriter clipboard_writer)
    : sender_(std::move(sender)),
      events_(std::move(events)),
      secrets_(secrets),
      hashes_(hashes),
      now_(std::move(now)),
      clipboard_writer_(std::move(clipboard_writer)) {}

bool RemoteControlController::Request(const std::string& account_id,
                                      const std::string& call_id,
                                      const std::string& peer_account,
                                      std::uint64_t source_revision,
                                      Capabilities capabilities,
                                      const std::string& identity_color) {
  Poll();
  if (account_id.empty() || !ValidCall(call_id) || !ValidPeer(peer_account) ||
      source_revision == 0 || !ValidCapabilities(capabilities) ||
      !identity_color_wire::Index(identity_color)) {
    return false;
  }
  const RequestMessage request{capabilities, source_revision, identity_color};
  const auto serialized =
      SerializePacket(Message{request}, WireDirection::kControllerToControllee);
  if (!serialized) return false;

  Session session;
  session.account_id = account_id;
  session.call_id = call_id;
  session.peer_account = peer_account;
  session.source_revision = source_revision;
  session.requested_capabilities = capabilities;
  session.request_started_ms = now_ ? now_() : 0;
  session.request_last_sent_ms = session.request_started_ms;
  session.identity_color = identity_color;
  std::optional<Session> replaced;
  {
    std::lock_guard<std::mutex> lock(mutex_);
    if (shutdown_) return false;
    replaced = session_;
    session_ = session;
    incoming_clipboards_.clear();
    observed_clipboard_ids_.clear();
    outgoing_clipboards_.clear();
  }
  if (replaced) {
    Send(replaced->call_id, Message{EndMessage{}},
         WireDirection::kControllerToControllee);
    EmitState(*replaced, "ended", "replaced");
  }
  if (!SendPacket(call_id, serialized.packet)) {
    {
      std::lock_guard<std::mutex> lock(mutex_);
      if (session_ && session_->call_id == session.call_id &&
          session_->source_revision == session.source_revision) {
        session_.reset();
      }
    }
    EmitState(session, "ended", "send-failed");
    return false;
  }
  EmitState(session, "requesting", "");
  return true;
}

bool RemoteControlController::Input(const std::string& call_id,
                                    const std::string& peer_account,
                                    std::uint64_t source_revision,
                                    std::vector<InputEvent> events) {
  Poll();
  if (events.empty() || events.size() > kMaxInputEvents) return false;
  std::string packet;
  std::string token;
  std::uint64_t epoch = 0;
  {
    std::lock_guard<std::mutex> lock(mutex_);
    if (shutdown_ || !MatchesLocked(call_id, peer_account, source_revision) ||
        !session_->active) {
      return false;
    }
    InputMessage input;
    input.token = session_->token;
    input.epoch = session_->epoch;
    input.sequence = session_->sequence + 1;
    input.source_revision = session_->source_revision;
    input.events = std::move(events);
    const auto serialized = SerializePacket(
        Message{input}, WireDirection::kControllerToControllee);
    if (!serialized) return false;
    session_->sequence = input.sequence;
    packet = serialized.packet;
    token = session_->token;
    epoch = session_->epoch;
  }
  if (SendPacket(call_id, packet)) return true;

  // A dropped input creates a permanent sequence gap at the controllee. Keep
  // neither cursor nor keyboard authority locally after transport rejects the
  // packet; a fresh request/grant is required to establish a new epoch.
  std::optional<Session> ended;
  {
    std::lock_guard<std::mutex> lock(mutex_);
    if (MatchesLocked(call_id, peer_account, source_revision) &&
        session_->active && session_->token == token &&
        session_->epoch == epoch) {
      ended = *session_;
      session_.reset();
      incoming_clipboards_.clear();
      observed_clipboard_ids_.clear();
      outgoing_clipboards_.clear();
    }
  }
  if (ended) {
    // The failed input retired the native token/sequence authority. A second,
    // best-effort end packet closes the remote host too when the first
    // rejection was a transient queue failure.
    (void) Send(call_id, Message{EndMessage{}},
                WireDirection::kControllerToControllee);
    EmitState(*ended, "ended", "send-failed");
  }
  return false;
}

bool RemoteControlController::End(const std::string& call_id,
                                  const std::string& peer_account,
                                  std::uint64_t source_revision) {
  Poll();
  Session ended;
  {
    std::lock_guard<std::mutex> lock(mutex_);
    if (shutdown_ || !MatchesLocked(call_id, peer_account, source_revision))
      return false;
    ended = *session_;
    session_.reset();
    incoming_clipboards_.clear();
    observed_clipboard_ids_.clear();
    outgoing_clipboards_.clear();
  }
  const bool sent =
      Send(call_id, Message{EndMessage{}},
           WireDirection::kControllerToControllee);
  // Local authority is already gone regardless of courtesy delivery. Always
  // publish the terminal state so Flutter cannot remain "controlling" after
  // the native token and sequence have been retired.
  EmitState(ended, "ended", sent ? "local" : "send-failed");
  return sent;
}

bool RemoteControlController::SendClipboard(
    const std::string& call_id,
    const std::string& peer_account,
    std::uint64_t source_revision,
    const std::string& utf8) {
  Poll();
  if (utf8.empty() || utf8.size() > kMaxClipboardBytes) return false;
  const auto id = secrets_.GenerateHex(16);
  const auto hash = hashes_.Sha256Hex(utf8);
  if (!id || !hash) return false;

  ClipboardOfferMessage offer{*id, *hash,
                              static_cast<std::uint32_t>(utf8.size())};
  ClipboardDataMessage data{*id, *hash, utf8};
  const auto offer_packet = SerializePacket(
      Message{offer}, WireDirection::kControllerToControllee);
  const auto data_packet = SerializePacket(
      Message{data}, WireDirection::kControllerToControllee);
  if (!offer_packet || !data_packet) return false;
  const auto sent_ms = now_ ? now_() : 0;

  {
    std::lock_guard<std::mutex> lock(mutex_);
    if (shutdown_ || !MatchesLocked(call_id, peer_account, source_revision) ||
        !session_->active ||
        !HasCapability(session_->granted_capabilities,
                       Capability::kClipboard)) {
      return false;
    }
    if (outgoing_clipboards_.size() >= 8) return false;
    outgoing_clipboards_[*id] =
        OutgoingClipboard{call_id, *hash, sent_ms};
  }
  if (SendPacket(call_id, offer_packet.packet) &&
      SendPacket(call_id, data_packet.packet)) {
    return true;
  }
  {
    std::lock_guard<std::mutex> lock(mutex_);
    outgoing_clipboards_.erase(*id);
  }
  return false;
}

bool RemoteControlController::RespondClipboard(
    const std::string& call_id,
    const std::string& peer_account,
    std::uint64_t source_revision,
    const std::string& id,
    std::uint64_t prompt_generation,
    bool accept) {
  Poll();
  {
    std::lock_guard<std::mutex> lock(mutex_);
    if (shutdown_ || !MatchesLocked(call_id, peer_account, source_revision) ||
        !session_->active) {
      return false;
    }
    const auto it = incoming_clipboards_.find(id);
    if (it == incoming_clipboards_.end() || !it->second.ready ||
        it->second.generation != prompt_generation ||
        !now_ || now_() < it->second.received_ms ||
        now_() - it->second.received_ms >= kClipboardTimeoutMs) {
      return false;
    }
    if (accept) {
      const auto& offer = it->second;
      const auto hash = hashes_.Sha256Hex(offer.text);
      if (offer.text.size() != offer.size || !hash || *hash != offer.sha256 ||
          !clipboard_writer_ || !clipboard_writer_(session_->account_id,
              session_->call_id, session_->peer_account, session_->peer_device,
              offer.text)) return false;
    }
    incoming_clipboards_.erase(it);
  }
  const Message response = accept
      ? Message{ClipboardAcceptMessage{id}}
      : Message{ClipboardRejectMessage{id}};
  return Send(call_id, response, WireDirection::kControllerToControllee);
}

bool RemoteControlController::OnControlMessage(
    const ControllerInboundEnvelope& envelope) {
  Poll();
  const auto parsed =
      ParsePacket(envelope.payload, WireDirection::kControlleeToController);
  if (!parsed) return false;

  std::optional<Session> state_session;
  std::optional<std::pair<std::string, std::string>> state;
  std::optional<ClipboardOffer> clipboard_request;
  std::optional<std::string> rejected_offer;
  std::optional<std::map<std::string, std::string>> clipboard_result;
  const auto received_ms = now_ ? now_() : 0;

  if (const auto* data = std::get_if<ClipboardDataMessage>(&*parsed.message)) {
    const auto reject = [this, &envelope, data] {
      const auto packet = SerializePacket(
          Message{ClipboardRejectMessage{data->id}},
          WireDirection::kControllerToControllee);
      if (packet) (void) SendPacket(envelope.call_id, packet.packet);
    };
    ClipboardOffer expected;
    bool malformed = false;
    {
      std::lock_guard<std::mutex> lock(mutex_);
      if (shutdown_ || !AuthenticatedEnvelopeMatchesLocked(envelope) ||
          !session_->active) {
        return false;
      }
      const auto it = incoming_clipboards_.find(data->id);
      if (it == incoming_clipboards_.end()) {
        malformed = true;
      } else if (it->second.ready) {
        return true;
      } else if (it->second.sha256 != data->sha256 ||
                 it->second.size != data->utf8.size()) {
        incoming_clipboards_.erase(it);
        malformed = true;
      } else {
        expected = it->second;
      }
    }
    if (malformed) {
      reject();
      return true;
    }
    const auto actual_hash = hashes_.Sha256Hex(data->utf8);
    if (!actual_hash || *actual_hash != data->sha256) {
      {
        std::lock_guard<std::mutex> lock(mutex_);
        const auto current = incoming_clipboards_.find(data->id);
        if (current == incoming_clipboards_.end() || current->second.generation != expected.generation) return true;
        incoming_clipboards_.erase(current);
      }
      reject();
      return true;
    }
    bool changed = false;
    {
      std::lock_guard<std::mutex> lock(mutex_);
      if (shutdown_ || !AuthenticatedEnvelopeMatchesLocked(envelope) ||
          !session_->active) {
        return true;
      }
      const auto it = incoming_clipboards_.find(data->id);
      if (it != incoming_clipboards_.end() && it->second.generation != expected.generation) return true;
      if (it != incoming_clipboards_.end() && it->second.ready) return true;
      if (it == incoming_clipboards_.end() ||
          it->second.sha256 != expected.sha256 ||
          it->second.size != expected.size) {
        if (it != incoming_clipboards_.end())
          incoming_clipboards_.erase(it);
        changed = true;
      } else {
        it->second.text = data->utf8;
        it->second.ready = true;
        clipboard_request = it->second;
        state_session = *session_;
      }
    }
    if (changed) reject();
  } else {
    std::lock_guard<std::mutex> lock(mutex_);
    if (shutdown_ || !AuthenticatedEnvelopeMatchesLocked(envelope))
      return false;
    std::visit(
        [this, &envelope, &state_session, &state, &clipboard_request,
         &clipboard_result, &rejected_offer, received_ms](const auto& message) {
          using T = std::decay_t<decltype(message)>;
          if constexpr (std::is_same_v<T, GrantMessage>) {
            if (session_->active ||
                message.source_revision != session_->source_revision ||
                (message.capabilities & ~session_->requested_capabilities) != 0) {
              return;
            }
            session_->account_id = envelope.account_id;
            session_->peer_device = envelope.peer_device;
            session_->granted_capabilities = message.capabilities;
            session_->token = message.token;
            session_->epoch = message.epoch;
            session_->sequence = 0;
            session_->active = true;
            state_session = *session_;
            state = std::make_pair("active", "");
          } else if constexpr (std::is_same_v<T, DenyMessage>) {
            state_session = *session_;
            state_session->account_id = envelope.account_id;
            state_session->peer_device = envelope.peer_device;
            session_.reset();
            incoming_clipboards_.clear();
            observed_clipboard_ids_.clear();
            outgoing_clipboards_.clear();
            state = std::make_pair("denied", DenyReasonName(message.reason));
          } else if constexpr (std::is_same_v<T, RevokeMessage>) {
            if (!session_->active) return;
            state_session = *session_;
            session_.reset();
            incoming_clipboards_.clear();
            observed_clipboard_ids_.clear();
            outgoing_clipboards_.clear();
            state = std::make_pair("revoked", "remote");
          } else if constexpr (std::is_same_v<T, EndMessage>) {
            state_session = *session_;
            session_.reset();
            incoming_clipboards_.clear();
            observed_clipboard_ids_.clear();
            outgoing_clipboards_.clear();
            state = std::make_pair("ended", "remote");
          } else if constexpr (std::is_same_v<T, ClipboardOfferMessage>) {
            if (!session_->active ||
                !HasCapability(session_->granted_capabilities,
                               Capability::kClipboard)) {
              return;
            }
            if (observed_clipboard_ids_.count(message.id)) return;
            if (observed_clipboard_ids_.size() >= 64) {
              rejected_offer = message.id;
              return;
            }
            observed_clipboard_ids_.insert(message.id);
            if (!incoming_clipboards_.empty()) {
              rejected_offer = message.id;
              return;
            }
            auto generation = next_clipboard_generation_++;
            if (next_clipboard_generation_ == 0) ++next_clipboard_generation_;
            incoming_clipboards_[message.id] = ClipboardOffer{
                message.id, message.sha256, message.size, {}, false,
                received_ms, generation};
          } else if constexpr (std::is_same_v<T, ClipboardAcceptMessage>) {
            if (!session_->active ||
                outgoing_clipboards_.erase(message.id) != 1) {
              return;
            }
            clipboard_result = std::map<std::string, std::string>{
                {"callId", session_->call_id},
                {"id", message.id},
                {"state", "accepted"},
                {"reason", ""}};
          } else if constexpr (std::is_same_v<T, ClipboardRejectMessage>) {
            if (!session_->active ||
                outgoing_clipboards_.erase(message.id) != 1) {
              return;
            }
            clipboard_result = std::map<std::string, std::string>{
                {"callId", session_->call_id},
                {"id", message.id},
                {"state", "rejected"},
                {"reason", "remote"}};
          }
        },
        *parsed.message);
  }

  if (state_session && state)
    EmitState(*state_session, state->first, state->second);
  if (rejected_offer) Send(envelope.call_id, Message{ClipboardRejectMessage{*rejected_offer}}, WireDirection::kControllerToControllee);
  if (state_session && clipboard_request)
    EmitClipboardRequest(*state_session, *clipboard_request);
  if (clipboard_result)
    Emit("remoteClipboardControllerResult", std::move(*clipboard_result));
  return true;
}

void RemoteControlController::OnCallEnded(const std::string& call_id) {
  std::optional<Session> ended;
  {
    std::lock_guard<std::mutex> lock(mutex_);
    if (!session_ || session_->call_id != call_id) return;
    ended = *session_;
    session_.reset();
    incoming_clipboards_.clear();
    observed_clipboard_ids_.clear();
    outgoing_clipboards_.clear();
  }
  EmitState(*ended, "ended", "call-ended");
}

void RemoteControlController::OnTrustReduced(
    const std::string& account_id, const std::string& peer_account) {
  std::optional<Session> ended;
  {
    std::lock_guard<std::mutex> lock(mutex_);
    if (!session_ || session_->account_id != account_id ||
        session_->peer_account != peer_account) return;
    ended = *session_;
    session_.reset();
    incoming_clipboards_.clear();
    observed_clipboard_ids_.clear();
    outgoing_clipboards_.clear();
  }
  EmitState(*ended, "ended", "trust-removed");
}

void RemoteControlController::Poll() {
  std::vector<std::pair<std::string, std::string>> timed_out;
  std::optional<Session> request_timeout;
  std::optional<Session> request_retry;
  const auto now = now_ ? now_() : 0;
  {
    std::lock_guard<std::mutex> lock(mutex_);
    if (shutdown_) return;
    PurgeExpiredLocked(now, timed_out, request_timeout);
    if (session_ && !session_->active &&
        (now < session_->request_last_sent_ms ||
         now - session_->request_last_sent_ms >= kRequestRetryMs)) {
      session_->request_last_sent_ms = now;
      request_retry = *session_;
    }
  }
  if (request_retry) {
    (void) Send(
        request_retry->call_id,
        Message{RequestMessage{request_retry->requested_capabilities,
                               request_retry->source_revision,
                               request_retry->identity_color}},
        WireDirection::kControllerToControllee);
  }
  if (request_timeout) {
    // Retire a host prompt (or a grant racing the timeout) instead of merely
    // forgetting the local request and leaving the peer active until its own
    // timer/safety cleanup.
    (void) Send(request_timeout->call_id, Message{EndMessage{}},
                WireDirection::kControllerToControllee);
    EmitState(*request_timeout, "denied", "timeout");
  }
  EmitTimeouts(timed_out);
}

void RemoteControlController::ReplayPendingEvents() {
  Poll();
  std::optional<Session> session;
  std::vector<ClipboardOffer> offers;
  {
    std::lock_guard<std::mutex> lock(mutex_);
    if (shutdown_ || !session_) return;
    session = *session_;
    for (const auto& [id, offer] : incoming_clipboards_) {
      if (offer.ready) offers.push_back(offer);
    }
  }
  EmitState(*session, session->active ? "active" : "requesting", "");
  for (const auto& offer : offers) EmitClipboardRequest(*session, offer);
}

void RemoteControlController::PurgeExpiredLocked(
    std::uint64_t now,
    std::vector<std::pair<std::string, std::string>>& timed_out,
    std::optional<Session>& request_timeout) {
  if (session_ && !session_->active &&
      (now < session_->request_started_ms ||
       now - session_->request_started_ms >= kRequestTimeoutMs)) {
    request_timeout = *session_;
    session_.reset();
    incoming_clipboards_.clear();
    observed_clipboard_ids_.clear();
    outgoing_clipboards_.clear();
    return;
  }
  for (auto it = incoming_clipboards_.begin();
       it != incoming_clipboards_.end();) {
    if (now < it->second.received_ms ||
        now - it->second.received_ms >= kClipboardTimeoutMs) {
      it = incoming_clipboards_.erase(it);
    } else {
      ++it;
    }
  }
  for (auto it = outgoing_clipboards_.begin();
       it != outgoing_clipboards_.end();) {
    if (now < it->second.sent_ms ||
        now - it->second.sent_ms >= kClipboardTimeoutMs) {
      timed_out.emplace_back(it->second.call_id, it->first);
      it = outgoing_clipboards_.erase(it);
    } else {
      ++it;
    }
  }
}

void RemoteControlController::EmitTimeouts(
    const std::vector<std::pair<std::string, std::string>>& timed_out) const {
  for (const auto& [call_id, id] : timed_out) {
    Emit("remoteClipboardControllerResult",
         {{"callId", call_id},
          {"id", id},
          {"state", "rejected"},
          {"reason", "timeout"}});
  }
}

void RemoteControlController::Shutdown() {
  std::optional<Session> ended;
  {
    std::lock_guard<std::mutex> lock(mutex_);
    if (shutdown_) return;
    shutdown_ = true;
    ended = session_;
    session_.reset();
    incoming_clipboards_.clear();
    observed_clipboard_ids_.clear();
    outgoing_clipboards_.clear();
  }
  // FlutterWindow invokes this before stopping the daemon worker, so the
  // courtesy end is still drainable. Local teardown never depends on success.
  if (ended) {
    (void) Send(ended->call_id, Message{EndMessage{}},
                WireDirection::kControllerToControllee);
  }
}

bool RemoteControlController::OwnsCall(const std::string& call_id) const {
  std::lock_guard<std::mutex> lock(mutex_);
  return !shutdown_ && session_ && session_->call_id == call_id;
}

bool RemoteControlController::MatchesLocked(
    const std::string& call_id,
    const std::string& peer_account,
    std::uint64_t source_revision) const {
  return session_ && session_->call_id == call_id &&
      session_->peer_account == peer_account &&
      session_->source_revision == source_revision;
}

bool RemoteControlController::AuthenticatedEnvelopeMatchesLocked(
    const ControllerInboundEnvelope& envelope) const {
  if (!session_ || session_->account_id != envelope.account_id ||
      session_->call_id != envelope.call_id ||
      session_->peer_account != envelope.peer_account ||
      !ValidPeer(envelope.peer_account) ||
      envelope.peer_device.size() < 40 ||
      envelope.peer_device.size() > 128 ||
      !IsLowerHex(envelope.peer_device)) {
    return false;
  }
  return session_->peer_device.empty() ||
      session_->peer_device == envelope.peer_device;
}

bool RemoteControlController::Send(const std::string& call_id,
                                   const Message& message,
                                   WireDirection direction) const {
  const auto packet = SerializePacket(message, direction);
  return packet && SendPacket(call_id, packet.packet);
}

bool RemoteControlController::SendPacket(
    const std::string& call_id,
    const std::string& packet) const {
  if (call_id.empty() || packet.empty() || !sender_) return false;
  try {
    return sender_(call_id, packet);
  } catch (...) {
    return false;
  }
}

void RemoteControlController::EmitState(const Session& session,
                                        const std::string& state,
                                        const std::string& reason) const {
  Emit("remoteControlControllerState",
       {{"accountId", session.account_id},
        {"callId", session.call_id},
        {"peerJamiId", session.peer_account},
        {"peerDeviceId", session.peer_device},
        {"sourceRevision", std::to_string(session.source_revision)},
        {"controlCapabilities",
         std::to_string(session.active ? session.granted_capabilities
                                       : session.requested_capabilities)},
        {"state", state},
        {"reason", reason}});
}

void RemoteControlController::EmitClipboardRequest(
    const Session& session,
    const ClipboardOffer& offer) const {
  Emit("remoteClipboardControllerRequest",
       {{"accountId", session.account_id},
        {"callId", session.call_id},
        {"peerJamiId", session.peer_account},
        {"peerDeviceId", session.peer_device},
        {"sourceRevision", std::to_string(session.source_revision)},
         {"id", offer.id},
         {"promptGeneration", std::to_string(offer.generation)},
        {"sha256", offer.sha256},
        {"clipboardBytes", std::to_string(offer.size)},
        {"text", offer.text}});
}

void RemoteControlController::Emit(
    const std::string& type,
    std::map<std::string, std::string> data) const {
  if (events_) events_(type, data);
}

const char* RemoteControlController::DenyReasonName(DenyReason reason) {
  switch (reason) {
    case DenyReason::kUser:
      return "user";
    case DenyReason::kTimeout:
      return "timeout";
    case DenyReason::kUnsupported:
      return "unsupported";
    case DenyReason::kBusy:
      return "busy";
  }
  return "unknown";
}

}  // namespace sybl::remote
