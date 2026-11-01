#ifdef NDEBUG
#undef NDEBUG
#endif
#include "device_pairing.h"
#include <cassert>
#include <iostream>

namespace pair = sybl::device_pairing;
const uint32_t op = 123456;
const std::string uri = "jami-auth://" + std::string(64, 'a') + "/123456/doorlight-v1";
const std::map<std::string, std::string> scheme{{"auth_scheme", "doorlight-code-v1"}};
auto Identity() {
  return std::map<std::string, std::string>{{"peer_id", std::string(40, 'b')},
      {"peer_device", std::string(64, 'c')}, {"device_id", std::string(64, 'd')}};
}
void Offer(pair::Flow& flow) {
  assert(flow.BindOperation(op));
  auto offered = scheme; offered["token"] = uri; offered["operation"] = "123456";
  assert(flow.Accept(op, 1, offered));
}
void Prepare(pair::Flow& flow) {
  Offer(flow);
  auto details = Identity(); details["auth_scheme"] = "doorlight-code-v1";
  assert(flow.Accept(op, 3, details));
  assert(flow.SubmittingCode());
  details["prepared"] = "true";
  assert(flow.Accept(op, 4, details));
}
void BoundInputs() {
  assert(pair::ValidOffer(uri));
  for (const auto& value : {uri + "?x=1", uri + "\n", uri.substr(0, uri.size() - 13),
       std::string("jami-auth://") + std::string(64, 'a') + "/012345/doorlight-v1"}) assert(!pair::ValidOffer(value));
  assert(pair::ValidCode("00123456"));
  for (const auto* value : {"1234567", "123456789", "1234 678", "12345678\n"}) assert(!pair::ValidCode(value));
  pair::Flow flow("f", "reserved", true); Offer(flow);
  assert(!flow.BindOperation(op + 1));
  assert(!flow.Accept(op + 1, 5, {{"error", "timeout"}}));
  assert(!flow.snapshot().terminal && flow.snapshot().status == "waiting");
  pair::Flow bad("f", "reserved", true); assert(!bad.BindOperation(1));
}
void SourceConsentAndExactIssuance() {
  pair::Flow flow("f", "source", false); assert(flow.BindOperation(7));
  assert(!flow.IssuedCode("00123456"));
  assert(flow.Accept(7, 2, {})); assert(!flow.Accept(7, 4, {}));
  assert(flow.Accept(7, 3, scheme)); assert(flow.IssuedCode("00123456"));
  assert(!flow.IssuedCode("87654321")); assert(flow.snapshot().code == "00123456");
  assert(flow.Accept(7, 4, {})); assert(flow.snapshot().code.empty());
  auto done = Identity(); done["error"] = ""; assert(flow.Accept(7, 5, done));
  assert(flow.snapshot().status == "complete"); assert(!flow.Accept(7, 3, scheme));
}
void NativeRetryAndStableIdentity() {
  pair::Flow flow("f", "reserved", true); Offer(flow);
  auto details = Identity(); details["auth_scheme"] = "doorlight-code-v1";
  assert(flow.Accept(op, 3, details)); assert(flow.SubmittingCode()); assert(!flow.SubmittingCode());
  auto changed = details; changed["peer_id"] = std::string(40, 'e'); assert(!flow.Accept(op, 3, changed));
  details["auth_error"] = "invalid_code";
  assert(flow.Accept(op, 3, details)); assert(flow.snapshot().invalid_code); assert(flow.SubmittingCode());
  details["prepared"] = "true"; details["device_id"] = details["peer_device"];
  assert(!flow.Accept(op, 4, details));
}
void PrivacyBeforeAcknowledgedActivation() {
  pair::Flow premature("f", "reserved", true); Prepare(premature);
  auto done = Identity(); done["error"] = "";
  assert(premature.Accept(op, 5, done)); assert(!premature.AcknowledgedDurably());
  assert(premature.snapshot().status == "confirming");
  pair::Flow flow("f", "reserved", true); Prepare(flow);
  assert(!flow.AcknowledgedDurably()); assert(flow.PreparedPrivacy()); assert(!flow.PreparedPrivacy());
  assert(flow.Accept(op, 5, done)); assert(flow.snapshot().status == "confirming");
  assert(flow.AcknowledgedDurably()); assert(flow.snapshot().status == "ready");
}
void RetirementRetainsTerminalOwnership() {
  pair::Flow flow("f", "reserved", true); Offer(flow); flow.Retire();
  assert(flow.snapshot().uri.empty() && flow.snapshot().status == "retired");
  assert(!flow.Accept(op, 3, scheme)); assert(!flow.snapshot().terminal);
  assert(flow.Accept(op, 5, {{"error", "canceled"}}));
  assert(flow.snapshot().terminal && flow.snapshot().status == "retired");
}
void UncertaintyIsNotRetryAuthority() {
  pair::Flow flow("f", "reserved", true); Prepare(flow); flow.Unconfirmed();
  assert(!flow.snapshot().terminal && flow.snapshot().status == "unconfirmed");
  assert(!flow.SubmittingCode() && !flow.AcknowledgedDurably());
  assert(flow.Accept(op, 5, {{"error", "network"}}));
  assert(flow.snapshot().status == "ended" && !flow.native_succeeded());
}
int main() {
  BoundInputs(); SourceConsentAndExactIssuance(); NativeRetryAndStableIdentity();
  PrivacyBeforeAcknowledgedActivation(); RetirementRetainsTerminalOwnership(); UncertaintyIsNotRetryAuthority();
  std::cout << "6 device pairing tests passed\n";
}
