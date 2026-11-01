#ifdef NDEBUG
#undef NDEBUG
#endif

#include "remote_control_controller.h"

#include <cassert>
#include <cstdio>
#include <map>
#include <string>
#include <utility>
#include <vector>

using namespace sybl::remote;

namespace {

constexpr auto kPeer = "0123456789abcdef0123456789abcdef01234567";
constexpr auto kOtherPeer = "1123456789abcdef0123456789abcdef01234567";
constexpr auto kDevice = "abcdef0123456789abcdef0123456789abcdef01";
constexpr auto kToken = "00112233445566778899aabbccddeeff";
constexpr auto kHash =
    "0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef";
constexpr auto kOtherHash =
    "1123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef";

class FakeCrypto final : public SecretSource, public HashProvider {
 public:
  std::optional<std::string> GenerateHex(std::size_t) override {
    char value[33]{};
    std::snprintf(value, sizeof(value), "%032llx",
                  static_cast<unsigned long long>(++generated));
    return value;
  }
  std::optional<std::string> Sha256Hex(std::string_view value) override {
    if (value == "hello") return kHash;
    return std::nullopt;
  }
  std::uint64_t generated = 0;
};

struct Harness {
  FakeCrypto crypto;
  std::uint64_t now = 1000;
  std::vector<std::pair<std::string, std::string>> packets;
  std::vector<std::pair<std::string, std::map<std::string, std::string>>> events;
  RemoteControlController controller{
      [this](const std::string& call, const std::string& packet) {
        ++send_attempts;
        if (fail_send || fail_next_sends > 0) {
          if (fail_next_sends > 0) --fail_next_sends;
          return false;
        }
        packets.emplace_back(call, packet);
        return true;
      },
      [this](const std::string& type,
             const std::map<std::string, std::string>& data) {
        events.emplace_back(type, data);
      },
      crypto,
      crypto,
      [this]() { return now; },
      [this](const std::string& account, const std::string& call,
          const std::string& peer, const std::string& device,
          const std::string& text) {
        assert(account == "local-account" && call == "call-1" && peer == kPeer && device == kDevice);
        if (fail_write) return false;
        assert(text == "hello");
        ++clipboard_writes;
        return true;
      }};
  bool fail_write = false;
  int clipboard_writes = 0;
  bool fail_send = false;
  int fail_next_sends = 0;
  int send_attempts = 0;

  bool Deliver(const Message& message,
               const std::string& peer = kPeer,
               const std::string& device = kDevice) {
    const auto packet =
        SerializePacket(message, WireDirection::kControlleeToController);
    assert(packet);
    return controller.OnControlMessage(
        {"local-account", "call-1", peer, device, packet.packet});
  }
};

Capabilities AllCaps() {
  return static_cast<Capabilities>(
      CapabilityBit(Capability::kMouse) |
      CapabilityBit(Capability::kKeyboard) |
      CapabilityBit(Capability::kText) |
      CapabilityBit(Capability::kClipboard));
}

void NativeOwnsGrantAndInputSequence() {
  Harness h;
  assert(!h.controller.Request("local-account", "call-1", "UPPER", 7, AllCaps()));
  assert(h.controller.Request("local-account", "call-1", kPeer, 7, AllCaps()));
  assert(h.packets.size() == 1);
  const auto request = ParsePacket(
      h.packets.back().second, WireDirection::kControllerToControllee);
  assert(request && std::holds_alternative<RequestMessage>(*request.message));

  assert(!h.Deliver(GrantMessage{kToken, 3, 7, AllCaps()}, kOtherPeer));
  assert(!h.controller.Input("call-1", kPeer, 7, {MoveEvent{0.5, 0.5}}));
  assert(h.Deliver(GrantMessage{kToken, 3, 7, AllCaps()}));
  assert(h.events.back().first == "remoteControlControllerState");
  assert(h.events.back().second.at("state") == "active");

  assert(h.controller.Input("call-1", kPeer, 7,
                            {MoveEvent{0.25, 0.75}, KeyEvent{65, true}}));
  assert(h.controller.Input("call-1", kPeer, 7, {KeyEvent{65, false}}));
  const auto first = ParsePacket(
      h.packets[h.packets.size() - 2].second,
      WireDirection::kControllerToControllee);
  const auto second = ParsePacket(
      h.packets.back().second, WireDirection::kControllerToControllee);
  assert(first && second);
  const auto& first_input = std::get<InputMessage>(*first.message);
  const auto& second_input = std::get<InputMessage>(*second.message);
  assert(first_input.token == kToken && first_input.epoch == 3);
  assert(first_input.sequence == 1 && second_input.sequence == 2);
  assert(!h.controller.Input("call-1", kPeer, 8, {KeyEvent{65, false}}));
}

void StaleGrantAndRevocationFailClosed() {
  Harness h;
  assert(h.controller.Request("local-account", "call-1", kPeer, 7,
                              CapabilityBit(Capability::kMouse)));
  assert(h.Deliver(GrantMessage{kToken, 3, 8,
                                CapabilityBit(Capability::kMouse)}));
  assert(!h.controller.Input("call-1", kPeer, 7, {MoveEvent{0.5, 0.5}}));
  assert(h.Deliver(DenyMessage{DenyReason::kBusy}));
  assert(h.events.back().second.at("state") == "denied");

  assert(h.controller.Request("local-account", "call-1", kPeer, 7,
                              CapabilityBit(Capability::kMouse)));
  assert(h.Deliver(GrantMessage{kToken, 4, 7,
                                CapabilityBit(Capability::kMouse)}));
  assert(h.Deliver(RevokeMessage{}));
  assert(h.events.back().second.at("state") == "revoked");
  assert(!h.controller.Input("call-1", kPeer, 7, {MoveEvent{0.5, 0.5}}));
}

void ClipboardIsNativeCorrelatedAndHashed() {
  Harness h;
  assert(h.controller.Request("local-account", "call-1", kPeer, 7, AllCaps()));
  assert(h.Deliver(GrantMessage{kToken, 3, 7, AllCaps()}));
  assert(h.controller.SendClipboard("call-1", kPeer, 7, "hello"));
  assert(h.packets.size() == 3);
  const auto offer = ParsePacket(
      h.packets[1].second, WireDirection::kControllerToControllee);
  const auto data = ParsePacket(
      h.packets[2].second, WireDirection::kControllerToControllee);
  assert(offer && data);
  const auto sent_id = std::get<ClipboardOfferMessage>(*offer.message).id;
  assert(std::get<ClipboardOfferMessage>(*offer.message).sha256 == kHash);
  assert(std::get<ClipboardDataMessage>(*data.message).utf8 == "hello");

  assert(h.Deliver(ClipboardAcceptMessage{sent_id}));
  assert(h.events.back().first == "remoteClipboardControllerResult");
  assert(h.events.back().second.at("state") == "accepted");

  const std::string inbound_id = "ffeeddccbbaa99887766554433221100";
  assert(h.Deliver(ClipboardOfferMessage{inbound_id, kHash, 5}));
  const auto events_before_crossed_data = h.events.size();
  assert(h.Deliver(ClipboardDataMessage{
      "00112233445566778899aabbccddeeff", kHash, "hello"}));
  assert(h.events.size() == events_before_crossed_data);
  const auto crossed_reject = ParsePacket(
      h.packets.back().second, WireDirection::kControllerToControllee);
  assert(crossed_reject &&
         std::get<ClipboardRejectMessage>(*crossed_reject.message).id ==
             "00112233445566778899aabbccddeeff");
  // The crossed id did not evict the original offer.
  assert(h.Deliver(ClipboardDataMessage{inbound_id, kHash, "hello"}));
  assert(h.events.back().first == "remoteClipboardControllerRequest");
  assert(h.events.back().second.at("text") == "hello");
  const auto prompt_generation =
      std::stoull(h.events.back().second.at("promptGeneration"));
  assert(prompt_generation > 0);
  assert(!h.controller.RespondClipboard("call-1", kPeer, 7, inbound_id,
                                        prompt_generation + 1, false));
  assert(h.controller.RespondClipboard("call-1", kPeer, 7, inbound_id,
                                       prompt_generation, false));
  const auto reject = ParsePacket(
      h.packets.back().second, WireDirection::kControllerToControllee);
  assert(reject &&
         std::holds_alternative<ClipboardRejectMessage>(*reject.message));
  assert(!h.controller.RespondClipboard("call-1", kPeer, 7, inbound_id,
                                        prompt_generation, true));

  const std::string corrupt_id = "00112233445566778899aabbccddee00";
  assert(h.Deliver(ClipboardOfferMessage{corrupt_id, kHash, 5}));
  const auto events_before_corruption = h.events.size();
  assert(h.Deliver(
      ClipboardDataMessage{corrupt_id, kOtherHash, "hello"}));
  assert(h.events.size() == events_before_corruption);
  const auto corrupt_reject = ParsePacket(
      h.packets.back().second, WireDirection::kControllerToControllee);
  assert(corrupt_reject &&
         std::get<ClipboardRejectMessage>(*corrupt_reject.message).id ==
             corrupt_id);
  // Matching corruption retires that offer instead of allowing a retry under
  // a consent record whose integrity contract was violated.
  assert(h.Deliver(ClipboardDataMessage{corrupt_id, kHash, "hello"}));
  assert(h.events.size() == events_before_corruption);
}

void ClipboardTimeoutsRecoverBothBoundedMaps() {
  Harness h;
  assert(h.controller.Request("local-account", "call-1", kPeer, 7, AllCaps()));
  assert(h.Deliver(GrantMessage{kToken, 3, 7, AllCaps()}));

  for (int i = 0; i < 8; ++i)
    assert(h.controller.SendClipboard("call-1", kPeer, 7, "hello"));
  assert(!h.controller.SendClipboard("call-1", kPeer, 7, "hello"));
  h.now = 21000;
  h.controller.Poll();
  int timeout_results = 0;
  for (const auto& event : h.events) {
    if (event.first == "remoteClipboardControllerResult" &&
        event.second.at("reason") == "timeout") {
      ++timeout_results;
    }
  }
  assert(timeout_results == 8);
  assert(h.controller.SendClipboard("call-1", kPeer, 7, "hello"));

  h.now = 30000;
  for (int i = 0; i < 8; ++i) {
    char id[17]{};
    std::snprintf(id, sizeof(id), "%016x", i + 1);
    assert(h.Deliver(ClipboardOfferMessage{id, kHash, 5}));
  }
  const std::string recovered_id = "0000000000000009";
  assert(h.Deliver(ClipboardOfferMessage{recovered_id, kHash, 5}));
  const auto before = h.events.size();
  assert(h.Deliver(
      ClipboardDataMessage{recovered_id, kHash, "hello"}));
  assert(h.events.size() == before);  // ninth live offer was capacity-capped

  h.now = 50000;
  h.controller.Poll();
  const auto after_expiry = h.events.size();
  assert(h.Deliver(ClipboardOfferMessage{recovered_id, kHash, 5}));
  assert(h.Deliver(
      ClipboardDataMessage{recovered_id, kHash, "hello"}));
  assert(h.events.size() == after_expiry); // busy and expired IDs stay terminal
  const std::string fresh_id = "000000000000000a";
  assert(h.Deliver(ClipboardOfferMessage{fresh_id, kHash, 5}));
  assert(h.Deliver(ClipboardDataMessage{fresh_id, kHash, "hello"}));
  assert(h.events.back().first == "remoteClipboardControllerRequest");
  assert(h.events.back().second.at("id") == fresh_id);
  const auto shown = h.events.size();
  assert(h.Deliver(ClipboardDataMessage{fresh_id, kHash, "hello"}));
  assert(h.events.size() == shown);
}

void EndAndCallEndTearDownAuthority() {
  Harness h;
  assert(h.controller.Request("local-account", "call-1", kPeer, 7, AllCaps()));
  assert(h.Deliver(GrantMessage{kToken, 3, 7, AllCaps()}));
  assert(h.controller.End("call-1", kPeer, 7));
  assert(h.events.back().second.at("state") == "ended");
  assert(!h.controller.Input("call-1", kPeer, 7, {MoveEvent{0.5, 0.5}}));

  assert(h.controller.Request("local-account", "call-1", kPeer, 7, AllCaps()));
  assert(h.Deliver(GrantMessage{kToken, 3, 7, AllCaps()}));
  h.controller.OnCallEnded("call-1");
  assert(h.events.back().second.at("reason") == "call-ended");
  assert(!h.controller.Input("call-1", kPeer, 7, {MoveEvent{0.5, 0.5}}));
}

void RequestTimeoutClearsPendingAuthorityAndAllowsRetry() {
  Harness h;
  assert(h.controller.Request("local-account", "call-1", kPeer, 7, AllCaps()));
  h.now = 20999;
  h.controller.Poll();
  assert(h.events.back().second.at("state") == "requesting");

  h.now = 21000;
  h.controller.Poll();
  const auto timeout_end = ParsePacket(
      h.packets.back().second, WireDirection::kControllerToControllee);
  assert(timeout_end &&
         std::holds_alternative<EndMessage>(*timeout_end.message));
  assert(h.events.back().first == "remoteControlControllerState");
  assert(h.events.back().second.at("state") == "denied");
  assert(h.events.back().second.at("reason") == "timeout");
  assert(!h.Deliver(GrantMessage{kToken, 3, 7, AllCaps()}));
  assert(!h.controller.Input("call-1", kPeer, 7,
                             {MoveEvent{0.5, 0.5}}));

  const auto packets_before_retry = h.packets.size();
  assert(h.controller.Request("local-account", "call-1", kPeer, 8, AllCaps()));
  assert(h.packets.size() == packets_before_retry + 1);
  const auto retry = ParsePacket(
      h.packets.back().second, WireDirection::kControllerToControllee);
  assert(retry);
  assert(std::get<RequestMessage>(*retry.message).source_revision == 8);
}

void PendingRequestRetriesUntilGrant() {
  Harness h;
  assert(h.controller.Request("local-account", "call-1", kPeer, 7, AllCaps()));
  assert(h.packets.size() == 1);

  h.now = 1999;
  h.controller.Poll();
  assert(h.packets.size() == 1);

  h.now = 2000;
  h.controller.Poll();
  assert(h.packets.size() == 2);
  const auto retry = ParsePacket(
      h.packets.back().second, WireDirection::kControllerToControllee);
  assert(retry && std::holds_alternative<RequestMessage>(*retry.message));
  assert(std::get<RequestMessage>(*retry.message).source_revision == 7);

  assert(h.Deliver(GrantMessage{kToken, 3, 7, AllCaps()}));
  h.now = 5000;
  h.controller.Poll();
  assert(h.packets.size() == 2);
}

void TransportRejectionNeverLeavesAuthorityArmed() {
  Harness h;
  h.fail_send = true;
  assert(!h.controller.Request("local-account", "call-1", kPeer, 7, AllCaps()));
  assert(!h.controller.OwnsCall("call-1"));
  assert(h.packets.empty());
  assert(h.events.back().second.at("state") == "ended");
  assert(h.events.back().second.at("reason") == "send-failed");

  h.fail_send = false;
  assert(h.controller.Request("local-account", "call-1", kPeer, 7, AllCaps()));
  assert(h.Deliver(GrantMessage{kToken, 3, 7, AllCaps()}));
  assert(h.controller.OwnsCall("call-1"));

  h.fail_send = true;
  assert(!h.controller.Input("call-1", kPeer, 7, {MoveEvent{0.5, 0.5}}));
  assert(!h.controller.OwnsCall("call-1"));
  assert(h.events.back().second.at("state") == "ended");
  assert(h.events.back().second.at("reason") == "send-failed");

  h.fail_send = false;
  assert(!h.controller.Input("call-1", kPeer, 7, {MoveEvent{0.6, 0.6}}));

  Harness transient;
  assert(transient.controller.Request("local-account", "call-1", kPeer, 7, AllCaps()));
  assert(transient.Deliver(GrantMessage{kToken, 3, 7, AllCaps()}));
  transient.fail_next_sends = 1;
  assert(!transient.controller.Input(
      "call-1", kPeer, 7, {MoveEvent{0.4, 0.4}}));
  const auto cleanup = ParsePacket(
      transient.packets.back().second,
      WireDirection::kControllerToControllee);
  assert(cleanup &&
         std::holds_alternative<EndMessage>(*cleanup.message));
}

void TrustRemovalRetiresPendingAndActiveOnlyForTheExactLocalPeer() {
  Harness h;
  assert(h.controller.Request("local-account", "call-1", kPeer, 7, AllCaps()));
  h.controller.OnTrustReduced("other-account", kPeer);
  h.controller.OnTrustReduced("local-account", kOtherPeer);
  assert(h.controller.OwnsCall("call-1"));
  h.controller.OnTrustReduced("local-account", kPeer);
  assert(!h.controller.OwnsCall("call-1"));
  assert(!h.Deliver(GrantMessage{kToken, 3, 7, AllCaps()}));
  assert(h.controller.Request("local-account", "call-1", kPeer, 7, AllCaps()));
  assert(h.Deliver(GrantMessage{kToken, 4, 7, AllCaps()}));
  h.controller.OnTrustReduced("local-account", kPeer);
  assert(!h.controller.Input("call-1", kPeer, 7, {MoveEvent{0.5, 0.5}}));
  assert(h.events.back().second.at("reason") == "trust-removed");
}

void LocalEndAndShutdownPublishOrSendCleanupDespiteFailure() {
  Harness failed_end;
  assert(failed_end.controller.Request("local-account", "call-1", kPeer, 7, AllCaps()));
  assert(failed_end.Deliver(GrantMessage{kToken, 3, 7, AllCaps()}));
  failed_end.fail_send = true;
  assert(!failed_end.controller.End("call-1", kPeer, 7));
  assert(!failed_end.controller.OwnsCall("call-1"));
  assert(failed_end.events.back().second.at("state") == "ended");
  assert(failed_end.events.back().second.at("reason") == "send-failed");

  Harness shutdown;
  assert(shutdown.controller.Request("local-account", "call-1", kPeer, 7, AllCaps()));
  assert(shutdown.Deliver(GrantMessage{kToken, 3, 7, AllCaps()}));
  const auto packets_before = shutdown.packets.size();
  shutdown.controller.Shutdown();
  assert(shutdown.packets.size() == packets_before + 1);
  const auto end = ParsePacket(
      shutdown.packets.back().second,
      WireDirection::kControllerToControllee);
  assert(end && std::holds_alternative<EndMessage>(*end.message));
  assert(!shutdown.controller.OwnsCall("call-1"));
}

}  // namespace

int main() {
  for (int retired = 0; retired < 6; ++retired) {
    Harness h;
    assert(h.controller.Request("local-account", "call-1", kPeer, 7, AllCaps()));
    assert(h.Deliver(GrantMessage{kToken, 3, 7, AllCaps()}));
    assert(h.Deliver(ClipboardOfferMessage{kToken, kHash, 5}));
    assert(h.Deliver(ClipboardDataMessage{kToken, kHash, "hello"}));
    const auto generation = std::stoull(h.events.back().second.at("promptGeneration"));
    if (retired == 1) h.controller.OnCallEnded("call-1");
    if (retired == 2) h.controller.OnTrustReduced("local-account", kPeer);
    if (retired == 3) h.now += 20000;
    if (retired == 4) h.fail_write = true;
    const auto revision = retired == 5 ? 8 : 7;
    const bool accepted = h.controller.RespondClipboard("call-1", kPeer, revision, kToken, generation, true);
    assert(accepted == (retired == 0));
    assert(h.clipboard_writes == (retired == 0 ? 1 : 0));
    if (retired == 0) assert(!h.controller.RespondClipboard("call-1", kPeer, 7, kToken, generation, true));
  }
  NativeOwnsGrantAndInputSequence();
  StaleGrantAndRevocationFailClosed();
  ClipboardIsNativeCorrelatedAndHashed();
  ClipboardTimeoutsRecoverBothBoundedMaps();
  EndAndCallEndTearDownAuthority();
  RequestTimeoutClearsPendingAuthorityAndAllowsRetry();
  PendingRequestRetriesUntilGrant();
  TransportRejectionNeverLeavesAuthorityArmed();
  LocalEndAndShutdownPublishOrSendCleanupDespiteFailure();
  TrustRemovalRetiresPendingAndActiveOnlyForTheExactLocalPeer();
}
