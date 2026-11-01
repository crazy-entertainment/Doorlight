#include "companion_input.h"
#include <cassert>
#include <atomic>

int main() {
  using namespace sybl::overlay;
  assert(ValidCombo("Ctrl+Alt+C"));
  assert(ValidCombo("F24"));
  assert(!ValidCombo("C"));
  assert(!ValidCombo("Ctrl+Ctrl+C"));
  assert(!ValidCombo("Ctrl+F25"));
  assert(!ValidCombo("Ctrl+VK_27"));
  assert(EmergencyStop(VK_ESCAPE, true, true, false));
  assert(EmergencyStop(VK_ESCAPE, true, false, true));
  assert(!EmergencyStop('C', true, true, true));
  assert(NextAim(false, false, true, true));
  assert(NextAim(true, true, true, true));
  assert(!NextAim(true, false, true, true));
  assert(!NextAim(true, true, false, false));
  std::atomic<int> drafts{0};
  CompanionInput input([&](InputEvent event) { if (event.type == "compose" || event.type == "submit") ++drafts; });
  // Configure alone never authenticates a peer or installs capture authority.
  InputConfig config; config.enabled = true; config.quick_chat_allowed = true;
  assert(input.Configure(config));
  assert(!input.Capture("chat.quick"));
  // A new authenticated lease still requires fresh Dart privacy authorization.
  input.SetConnected(true);
  assert(!input.Capture("chat.quick"));
  input.SetConnected(false);
  config.hotkeys["chat.quick"] = "C";
  assert(!input.Configure(config));
  config.hotkeys.clear(); config.cross_hold = "invalid";
  assert(!input.Configure(config));
  input.SetConnected(false);
  input.Stop();
  assert(drafts == 0);
}
