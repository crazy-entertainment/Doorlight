#ifdef NDEBUG
#undef NDEBUG
#endif

#include "remote_control_protocol.h"
#include "control_message_admission.h"

#include <cassert>
#include <limits>
#include <string>
#include <variant>

using namespace sybl::remote;

namespace {

constexpr auto kToken = "00112233445566778899aabbccddeeff";
constexpr auto kClipId = "0011223344556677";
constexpr auto kHash =
    "0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef";

void PacketEnvelopeIsStrict() {
  static_assert(kMaxJsonDepth == 20);
  assert(ParsePacket("", WireDirection::kControllerToControllee).error ==
         ProtocolError::kPacketEmpty);
  assert(ParsePacket(std::string(kMaxPacketBytes + 1, 'x'),
                     WireDirection::kControllerToControllee)
             .error == ProtocolError::kPacketTooLarge);
  assert(ParsePacket("[]", WireDirection::kControllerToControllee).error ==
         ProtocolError::kRootNotObject);
  assert(ParsePacket(R"({"v":2,"t":"end"})",
                     WireDirection::kControllerToControllee)
             .error == ProtocolError::kWrongVersion);
  assert(ParsePacket(R"({"v":1,"t":"end","extra":true})",
                     WireDirection::kControllerToControllee)
             .error == ProtocolError::kUnknownOrMissingField);
  assert(ParsePacket(R"({"v":1,"v":1,"t":"end"})",
                     WireDirection::kControllerToControllee)
             .error == ProtocolError::kMalformedJson);
  assert(ParsePacket(R"({"v":1,"t":"unknown"})",
                     WireDirection::kControllerToControllee)
             .error == ProtocolError::kUnknownType);

  // The root value starts at depth 1; 19 arrays plus their scalar reach 20.
  assert(ParsePacket(std::string(19, '[') + "0" + std::string(19, ']'),
                     WireDirection::kControllerToControllee)
             .error == ProtocolError::kRootNotObject);
  assert(ParsePacket(std::string(20, '[') + "0" + std::string(20, ']'),
                     WireDirection::kControllerToControllee)
             .error == ProtocolError::kMalformedJson);

  // Deep nesting must fail INERT like any other malformed packet. jsoncpp
  // enforces stackLimit by throwing, not by returning false, so without the
  // try/catch in ParsePacket these escape the error taxonomy entirely and
  // unwind out of the parser. Both a bare array and a well-formed envelope
  // carrying a deep "ev" reach the limit; neither may throw.
  assert(ParsePacket(std::string(40, '[') + "0" + std::string(40, ']'),
                     WireDirection::kControllerToControllee)
             .error == ProtocolError::kMalformedJson);
  assert(ParsePacket(R"({"v":1,"t":"end","x":)" + std::string(40, '[') + "0" +
                         std::string(40, ']') + "}",
                     WireDirection::kControllerToControllee)
             .error == ProtocolError::kMalformedJson);
  // Nested objects trip the same limit.
  {
    std::string deep;
    for (int i = 0; i < 40; ++i) deep += R"({"a":)";
    deep += "0";
    deep += std::string(40, '}');
    assert(ParsePacket(deep, WireDirection::kControllerToControllee).error ==
           ProtocolError::kMalformedJson);
  }
}

void CommentsOutsideStringsAreRejected() {
  for (const auto* packet : {
           R"({/*member*/"v":1,"t":"end"})",
           R"({"v":1,/*member*/"t":"end"})",
           R"({"v":1,"t":/*value*/"end"})",
           R"({"v":1,"t":"end"/*tail*/})",
           "{\"v\":1,//member\n\"t\":\"end\"}",
           R"({"v":1,"t":"req","caps":[/*item*/"mouse"],"color":"amber","sourceRevision":4})",
       }) {
    assert(ParsePacket(packet, WireDirection::kControllerToControllee).error ==
           ProtocolError::kMalformedJson);
  }

  const auto parsed = ParsePacket(
      std::string(R"({"v":1,"t":"input","token":")") + kToken +
          R"(","epoch":7,"seq":9,"sourceRevision":4,"ev":[["t","http://peer/a /* text */ // text"],["t","quote: \" // text"],["t","slash: \\ // text"],["t","escaped slash: \/"]]})",
      WireDirection::kControllerToControllee);
  assert(parsed);
  const auto& events = std::get<InputMessage>(*parsed.message).events;
  assert(std::get<TextEvent>(events[0]).utf8 ==
         "http://peer/a /* text */ // text");
  assert(std::get<TextEvent>(events[1]).utf8 == "quote: \" // text");
  assert(std::get<TextEvent>(events[2]).utf8 == "slash: \\ // text");
  assert(std::get<TextEvent>(events[3]).utf8 == "escaped slash: /");
}

void PacketByteBoundariesAndSerializerOverflowAreExact() {
  static_assert(kMaxPacketBytes == 6000);
  const std::string end = R"({"v":1,"t":"end"})";
  const auto padded = end + std::string(6000 - end.size(), ' ');
  assert(ParsePacket(padded, WireDirection::kControllerToControllee));
  assert(ParsePacket(padded + " ", WireDirection::kControllerToControllee)
             .error == ProtocolError::kPacketTooLarge);

  InputMessage input{kToken, 7, 9, 4, {}};
  input.events.assign(22, TextEvent{std::string(256, 'x')});
  input.events.emplace_back(TextEvent{"x"});
  const auto initial = SerializePacket(
      Message{input}, WireDirection::kControllerToControllee);
  assert(initial && initial.packet.size() < 6000);
  auto& final_text = std::get<TextEvent>(input.events.back()).utf8;
  final_text.append(6000 - initial.packet.size(), 'x');
  assert(final_text.size() < kMaxTextEventBytes);
  const auto exact = SerializePacket(
      Message{input}, WireDirection::kControllerToControllee);
  assert(exact && exact.packet.size() == 6000);
  assert(ParsePacket(exact.packet, WireDirection::kControllerToControllee));
  final_text += 'x';
  const auto overflow = SerializePacket(
      Message{input}, WireDirection::kControllerToControllee);
  assert(overflow.error == ProtocolError::kPacketTooLarge);
  assert(overflow.packet.empty());

  const auto multibyte = ParsePacket(
      std::string(R"({"v":1,"t":"input","token":")") + kToken +
          R"(","epoch":7,"seq":9,"sourceRevision":4,"ev":[["t","é"]]})",
      WireDirection::kControllerToControllee);
  assert(multibyte);
  const auto encoded = SerializePacket(
      *multibyte.message, WireDirection::kControllerToControllee);
  assert(encoded);
  const auto multibyte_exact =
      encoded.packet + std::string(6000 - encoded.packet.size(), ' ');
  assert(ParsePacket(multibyte_exact, WireDirection::kControllerToControllee));
  assert(ParsePacket(multibyte_exact + " ", WireDirection::kControllerToControllee)
             .error == ProtocolError::kPacketTooLarge);
}

void NonfiniteCoordinatesFailClosed() {
  for (const auto number : {std::numeric_limits<double>::quiet_NaN(),
                            std::numeric_limits<double>::infinity(),
                            -std::numeric_limits<double>::infinity()}) {
    for (const auto event : {MoveEvent{number, 0.5}, MoveEvent{0.5, number}}) {
      const auto encoded = SerializePacket(
          Message{InputMessage{kToken, 7, 9, 4, {event}}},
          WireDirection::kControllerToControllee);
      assert(!encoded);
      assert(encoded.packet.empty());
    }
  }
  for (const auto* number : {"NaN", "Infinity", "-Infinity", "1e9999"}) {
    const auto packet = std::string(R"({"v":1,"t":"input","token":")") +
        kToken + R"(","epoch":7,"seq":9,"sourceRevision":4,"ev":[["m",)" +
        number + ",0.5]]}";
    assert(!ParsePacket(packet, WireDirection::kControllerToControllee));
  }
}

void DirectionsAndCapabilitiesAreExact() {
  const auto request = ParsePacket(
      R"({"v":1,"t":"req","caps":["mouse","keyboard"],"sourceRevision":4,"color":"sage"})",
      WireDirection::kControllerToControllee);
  assert(request);
  const auto* decoded = std::get_if<RequestMessage>(&*request.message);
  assert(decoded);
  assert(decoded->source_revision == 4);
  assert(decoded->identity_color == "sage");
  assert(HasCapability(decoded->capabilities, Capability::kMouse));
  assert(HasCapability(decoded->capabilities, Capability::kKeyboard));
  assert(!HasCapability(decoded->capabilities, Capability::kClipboard));
  const auto android_request = ParsePacket(
      R"({"v":1,"t":"req","caps":["mouse","text","back","home","recents"],"color":"amber","sourceRevision":4})",
      WireDirection::kControllerToControllee);
  assert(android_request);
  const auto* android_decoded =
      std::get_if<RequestMessage>(&*android_request.message);
  assert(android_decoded);
  assert(HasCapability(android_decoded->capabilities, Capability::kBack));
  assert(HasCapability(android_decoded->capabilities, Capability::kHome));
  assert(HasCapability(android_decoded->capabilities, Capability::kRecents));
  assert(ParsePacket(
             R"({"v":1,"t":"req","caps":["mouse"],"color":"amber","sourceRevision":4})",
             WireDirection::kControlleeToController)
             .error == ProtocolError::kWrongDirection);
  assert(ParsePacket(
             R"({"v":1,"t":"grant","token":"00112233445566778899aabbccddeeff","epoch":1,"sourceRevision":4,"caps":["mouse"]})",
             WireDirection::kControllerToControllee)
             .error == ProtocolError::kWrongDirection);
  assert(ParsePacket(
             R"({"v":1,"t":"req","caps":["mouse","mouse"],"color":"amber","sourceRevision":4})",
             WireDirection::kControllerToControllee)
             .error == ProtocolError::kInvalidValue);
  assert(ParsePacket(
             R"({"v":1,"t":"req","caps":["camera"],"color":"amber","sourceRevision":4})",
             WireDirection::kControllerToControllee)
             .error == ProtocolError::kInvalidValue);
  assert(ParsePacket(
             R"({"v":1,"t":"deny","reason":"timeout"})",
             WireDirection::kControlleeToController));
  assert(ParsePacket(R"({"v":1,"t":"revoke"})",
                     WireDirection::kControlleeToController));
  assert(ParsePacket(R"({"v":1,"t":"end"})",
                     WireDirection::kControllerToControllee));
  assert(ParsePacket(R"({"v":1,"t":"end"})",
                     WireDirection::kControlleeToController));
}

void InputEventsAreBoundedAndTyped() {
  const std::string packet =
      std::string(R"({"v":1,"t":"input","token":")") + kToken +
      R"(","epoch":7,"seq":9,"sourceRevision":4,"ev":[["m",0,1],["d","left"],["u","left"],["w",-120],["k",65,true],["k",65,false],["t","héllo"]]})";
  const auto parsed = ParsePacket(packet, WireDirection::kControllerToControllee);
  assert(parsed);
  const auto* input = std::get_if<InputMessage>(&*parsed.message);
  assert(input);
  assert(input->events.size() == 7);
  assert(std::get<MoveEvent>(input->events[0]).x == 0);
  assert(std::get<ButtonEvent>(input->events[1]).down);
  assert(std::get<WheelEvent>(input->events[3]).delta == -120);
  assert(std::get<KeyEvent>(input->events[4]).virtual_key == 65);
  const auto action = ParsePacket(
      std::string(R"({"v":1,"t":"input","token":")") + kToken +
          R"(","epoch":7,"seq":10,"sourceRevision":4,"ev":[["a","home"]]})",
      WireDirection::kControllerToControllee);
  assert(action);
  const auto* action_input = std::get_if<InputMessage>(&*action.message);
  assert(action_input && action_input->events.size() == 1);
  assert(std::get<ActionEvent>(action_input->events[0]).action ==
         GlobalAction::kHome);
  assert(ParsePacket(
             std::string(R"({"v":1,"t":"input","token":")") + kToken +
                 R"(","epoch":7,"seq":10,"sourceRevision":4,"ev":[["a","power"]]})",
             WireDirection::kControllerToControllee)
             .error == ProtocolError::kInvalidValue);
  assert(ParsePacket(
             R"({"v":1,"t":"req","caps":["mouse"],"sourceRevision":4})",
             WireDirection::kControllerToControllee)
             .error == ProtocolError::kUnknownOrMissingField);
  assert(ParsePacket(
             R"({"v":1,"t":"req","caps":["mouse"],"color":"ultraviolet","sourceRevision":4})",
             WireDirection::kControllerToControllee)
             .error == ProtocolError::kInvalidValue);
  assert(std::get<TextEvent>(input->events[6]).utf8 == "héllo");

  assert(ParsePacket(
             std::string(R"({"v":1,"t":"input","token":")") + kToken +
                 R"(","epoch":7,"seq":9,"sourceRevision":4,"ev":[["m",-0.1,1]]})",
             WireDirection::kControllerToControllee)
             .error == ProtocolError::kInvalidValue);
  assert(ParsePacket(
             std::string(R"({"v":1,"t":"input","token":")") + kToken +
                 R"(","epoch":7,"seq":9,"sourceRevision":4,"ev":[["k",256,true]]})",
             WireDirection::kControllerToControllee)
             .error == ProtocolError::kInvalidValue);
  assert(ParsePacket(
             std::string(R"({"v":1,"t":"input","token":")") + kToken +
                 R"(","epoch":7,"seq":9,"sourceRevision":4,"ev":[["w",0]]})",
             WireDirection::kControllerToControllee)
             .error == ProtocolError::kInvalidValue);

  InputMessage too_many;
  too_many.token = kToken;
  too_many.epoch = 1;
  too_many.sequence = 1;
  too_many.source_revision = 1;
  too_many.events.assign(kMaxInputEvents + 1, MoveEvent{0.5, 0.5});
  assert(SerializePacket(Message{too_many},
                         WireDirection::kControllerToControllee)
             .error == ProtocolError::kTooManyEvents);
}

void ClipboardIsCorrelatedAndByteBounded() {
  const auto offer = ParsePacket(
      std::string(R"({"v":1,"t":"clip-offer","id":")") + kClipId +
          R"(","sha256":")" + kHash + R"(","size":5})",
      WireDirection::kControllerToControllee);
  assert(offer);
  assert(ParsePacket(
             std::string(R"({"v":1,"t":"clip-data","id":")") + kClipId +
                 R"(","sha256":")" + kHash + R"(","text":"hello"})",
             WireDirection::kControlleeToController));
  assert(ParsePacket(
             std::string(R"({"v":1,"t":"clip-offer","id":")") + kClipId +
                 R"(","sha256":")" + kHash + R"(","size":4097})",
             WireDirection::kControllerToControllee)
             .error == ProtocolError::kInvalidValue);
  assert(ParsePacket(
             R"({"v":1,"t":"clip-accept","id":"short"})",
             WireDirection::kControllerToControllee)
             .error == ProtocolError::kUnknownOrMissingField);
}

void RoundTripValidatesTheModel() {
  GrantMessage grant{kToken, 8, 11,
                     static_cast<Capabilities>(
                         CapabilityBit(Capability::kMouse) |
                         CapabilityBit(Capability::kKeyboard))};
  const auto encoded =
      SerializePacket(Message{grant}, WireDirection::kControlleeToController);
  assert(encoded);
  assert(encoded.packet.size() <= kMaxPacketBytes);
  const auto decoded =
      ParsePacket(encoded.packet, WireDirection::kControlleeToController);
  assert(decoded);
  const auto* value = std::get_if<GrantMessage>(&*decoded.message);
  assert(value && value->epoch == 8 && value->source_revision == 11);

  const auto wrong =
      SerializePacket(Message{grant}, WireDirection::kControllerToControllee);
  assert(wrong.error == ProtocolError::kWrongDirection);
  GrantMessage bad{"not-a-token", 8, 11, CapabilityBit(Capability::kMouse)};
  assert(SerializePacket(Message{bad}, WireDirection::kControlleeToController)
             .error == ProtocolError::kInvalidValue);
}

void CanonicalBytesMatchCrossLanguageGolden() {
  const auto request = SerializePacket(
      Message{RequestMessage{
          static_cast<Capabilities>(
              CapabilityBit(Capability::kMouse) |
              CapabilityBit(Capability::kKeyboard)),
          4}},
      WireDirection::kControllerToControllee);
  assert(request);
  assert(request.packet ==
         R"({"caps":["mouse","keyboard"],"color":"amber","sourceRevision":4,"t":"req","v":1})");

  InputMessage input;
  input.token = kToken;
  input.epoch = 7;
  input.sequence = 9;
  input.source_revision = 4;
  input.events = {
      MoveEvent{0.25, 0.75},
      ButtonEvent{MouseButton::kLeft, true},
  };
  const auto encoded = SerializePacket(
      Message{input}, WireDirection::kControllerToControllee);
  assert(encoded);
  assert(encoded.packet ==
         R"({"epoch":7,"ev":[["m",0.25,0.75],["d","left"]],"seq":9,"sourceRevision":4,"t":"input","token":"00112233445566778899aabbccddeeff","v":1})");
}

}  // namespace

int main() {
  ControlMessageAdmission admission;
  assert(!admission.Admit("a", "c", "p", kMaxPacketBytes + 1, 1000));
  for (int i = 0; i < 64; ++i) assert(admission.Admit("a", "c", "p", kMaxPacketBytes, 1000));
  assert(!admission.Admit("a", "c", "p", 1, 1000));
  assert(admission.Admit("a", "c", "other", 1, 1000));
  assert(admission.Admit("a", "c", "p", 1, 1010));
  PacketEnvelopeIsStrict();
  CommentsOutsideStringsAreRejected();
  PacketByteBoundariesAndSerializerOverflowAreExact();
  NonfiniteCoordinatesFailClosed();
  DirectionsAndCapabilitiesAreExact();
  InputEventsAreBoundedAndTyped();
  ClipboardIsCorrelatedAndByteBounded();
  RoundTripValidatesTheModel();
  CanonicalBytesMatchCrossLanguageGolden();
}
