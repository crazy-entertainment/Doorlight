#pragma once

#include <windows.h>

#include <functional>
#include <map>
#include <memory>
#include <string>

namespace sybl::overlay {
struct InputConfig {
  bool enabled = false;
  bool quick_chat_allowed = false;
  bool aim_toggle = false;
  std::string cross_hold = "off";
  std::string owner;
  std::map<std::string, std::string> hotkeys;
};
struct InputEvent {
  std::string type, action, text, button, owner;
  bool down = false, eligible = false;
  int x = 0, y = 0, mask = 0;
};
bool ValidCombo(const std::string& combo);
bool EmergencyStop(UINT key, bool ctrl, bool alt, bool shift);
bool NextAim(bool aiming, bool was_down, bool down, bool toggle);

// Hooks live on a dedicated message thread; neither pipe workers nor Flutter
// callbacks may execute application logic inside a low-level hook.
class CompanionInput {
 public:
  using Sink = std::function<void(InputEvent)>;
  explicit CompanionInput(Sink sink);
  ~CompanionInput();
  bool Configure(InputConfig config);
  void SetConnected(bool connected);
  bool Capture(std::string action);
  void Cancel();
  void Stop();
 private:
  struct Impl;
  std::unique_ptr<Impl> impl_;
};
}  // namespace sybl::overlay
