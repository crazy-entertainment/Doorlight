#include "companion_input.h"
#include "remote_control_win32_constants.h"

#include <shellapi.h>
#include <algorithm>
#include <atomic>
#include <climits>
#include <cstdlib>
#include <iterator>
#include <mutex>
#include <thread>
#include <utility>

namespace sybl::overlay {
namespace {
constexpr UINT kUpdate = WM_APP + 81;
constexpr size_t kMaxDraft = 4096;
struct Combo { UINT key = 0; bool ctrl = false, alt = false, shift = false, win = false; };
bool Parse(const std::string& text, Combo& result) {
  if (text.empty() || text.size() > 64) return false;
  size_t start = 0;
  while (true) {
    const auto end = text.find('+', start);
    const auto part = text.substr(start, end == std::string::npos ? end : end - start);
    if (end == std::string::npos) {
      if (part.size() == 1 && ((part[0] >= 'A' && part[0] <= 'Z') ||
                             (part[0] >= '0' && part[0] <= '9'))) result.key = part[0];
      else if (part.size() >= 2 && part.size() <= 3 && part[0] == 'F') {
        unsigned number = 0;
        for (size_t i = 1; i < part.size(); ++i) {
          if (part[i] < '0' || part[i] > '9') return false;
          number = number * 10 + static_cast<unsigned>(part[i] - '0');
        }
        if (number < 1 || number > 24) return false;
        result.key = VK_F1 + number - 1;
      } else return false;
      return result.ctrl || result.alt || result.shift || result.win || result.key >= VK_F1;
    }
    bool* modifier = part == "Ctrl" ? &result.ctrl : part == "Alt" ? &result.alt :
                     part == "Shift" ? &result.shift : part == "Win" ? &result.win : nullptr;
    if (!modifier || *modifier) return false;
    *modifier = true;
    start = end + 1;
  }
}
bool Down(int key) { return key && (GetAsyncKeyState(key) & 0x8000) != 0; }
int HoldKey(const std::string& name) {
  return name == "left" ? VK_LBUTTON : name == "right" ? VK_RBUTTON :
      name == "middle" ? VK_MBUTTON : name == "x1" ? VK_XBUTTON1 :
      name == "x2" ? VK_XBUTTON2 : name == "shift" ? VK_SHIFT :
      name == "ctrl" ? VK_CONTROL : 0;
}
std::string Utf8(const std::wstring& value) {
  if (value.empty()) return {};
  const auto size = WideCharToMultiByte(CP_UTF8, WC_ERR_INVALID_CHARS, value.data(),
      static_cast<int>(value.size()), nullptr, 0, nullptr, nullptr);
  if (!size) return {};
  std::string out(static_cast<size_t>(size), '\0');
  WideCharToMultiByte(CP_UTF8, WC_ERR_INVALID_CHARS, value.data(),
      static_cast<int>(value.size()), out.data(), size, nullptr, nullptr);
  return out;
}
bool InteractiveDesktop() {
  HDESK desktop = OpenInputDesktop(0, FALSE, DESKTOP_READOBJECTS);
  if (!desktop) return false;
  wchar_t name[64]{}; DWORD required = 0;
  const bool ok = GetUserObjectInformationW(desktop, UOI_NAME, name, sizeof(name), &required) &&
      _wcsicmp(name, L"Default") == 0;
  CloseDesktop(desktop);
  return ok;
}
}  // namespace
bool ValidCombo(const std::string& combo) { Combo parsed; return Parse(combo, parsed); }
bool EmergencyStop(UINT key, bool ctrl, bool alt, bool shift) {
  return key == VK_ESCAPE && ctrl && (alt || shift);
}
bool NextAim(bool aiming, bool was_down, bool down, bool toggle) {
  return toggle ? (down && !was_down ? !aiming : aiming) : down;
}

struct CompanionInput::Impl {
  static thread_local Impl* current;
  Sink sink;
  std::mutex mutex;
  InputConfig desired, config;
  std::string requested_capture;
  std::atomic<bool> connected{false}, permitted{false}, quick_permitted{false}, stopping{false};
  std::atomic<DWORD> thread_id{0};
  std::atomic<uint64_t> config_generation{0}, applied_generation{0};
  HANDLE ready = CreateEventW(nullptr, TRUE, FALSE, nullptr);
  std::thread thread;
  HHOOK keyboard = nullptr, mouse = nullptr;
  HWND foreground = nullptr;
  bool composing = false, aim_down = false, aiming = false;
  bool cancel_requested = false;
  std::string capture;
  std::wstring draft;
  std::string composing_owner;
  bool swallowed[256]{};
  bool physical_keys[256]{};
  POINT last_cursor{LONG_MIN, LONG_MIN};
  ULONGLONG last_center = 0, cursor_locked_until = 0;
  int center_returns = 0;
  int physical_mask = 0;
  bool last_eligible = false;
  int last_mask = -1;
  ULONGLONG last_cursor_event = 0;

  explicit Impl(Sink s) : sink(std::move(s)) {
    if (ready) {
      thread = std::thread([this] { Run(); });
      WaitForSingleObject(ready, INFINITE);
    }
  }
  ~Impl() { if (ready) CloseHandle(ready); }
  bool Allowed() const {
    return connected && permitted && !stopping && config_generation == applied_generation;
  }
  void Wake() { const auto id = thread_id.load(); if (id) PostThreadMessageW(id, kUpdate, 0, 0); }
  void Emit(InputEvent event) {
    if (event.type == "compose" || event.type == "submit" || event.type == "cancel") event.owner = composing_owner;
    if (!stopping) sink(std::move(event));
  }
  void Event(const char* type) { InputEvent event; event.type = type; Emit(std::move(event)); }
  void ResetAim() {
    aiming = false; aim_down = Down(HoldKey(config.cross_hold));
    Event("aimReset");
  }
  void EndCompose() {
    if (composing) { composing = false; draft.clear(); Event("cancel"); composing_owner.clear(); }
  }
  void Retire() {
    EndCompose();
    if (!capture.empty()) { capture.clear(); Event("cancel"); }
    if (keyboard || mouse || aiming || aim_down) ResetAim();
  }
  void Hooks(bool on) {
    if (on && !keyboard && !mouse) {
      foreground = GetForegroundWindow(); physical_mask = 0;
      keyboard = SetWindowsHookExW(WH_KEYBOARD_LL, Keyboard, GetModuleHandleW(nullptr), 0);
      mouse = SetWindowsHookExW(WH_MOUSE_LL, Mouse, GetModuleHandleW(nullptr), 0);
      if (!keyboard || !mouse) {
        permitted = false;
        InputEvent event; event.type = "blocked"; event.text = "input_unavailable"; Emit(event);
        on = false;
      }
    }
    if (!on) {
      if (keyboard) UnhookWindowsHookEx(keyboard);
      if (mouse) UnhookWindowsHookEx(mouse);
      keyboard = nullptr; mouse = nullptr;
      std::fill(std::begin(swallowed), std::end(swallowed), false);
      std::fill(std::begin(physical_keys), std::end(physical_keys), false);
      physical_mask = 0;
      aiming = false; aim_down = false;
    }
  }
  void Update() {
    bool cancel = false;
    std::string next_capture;
    {
      std::lock_guard<std::mutex> lock(mutex);
      const bool changed = config.cross_hold != desired.cross_hold || config.aim_toggle != desired.aim_toggle;
      if (config.owner != desired.owner) Retire();
      config = desired;
      applied_generation = config_generation.load();
      if (changed) ResetAim();
      next_capture.swap(requested_capture);
      cancel = cancel_requested; cancel_requested = false;
    }
    if (!Allowed() || cancel) { Retire(); Hooks(false); }
    else if (!config.quick_chat_allowed) EndCompose();
    Hooks(Allowed());
    if (Allowed() && !next_capture.empty()) { EndCompose(); ResetAim(); capture = std::move(next_capture); }
  }
  void Observe(const std::string& button, bool down) {
    if (!Allowed()) return;
    const std::string buttons[] = {"left", "right", "middle", "x1", "x2", "shift", "ctrl"};
    for (int i = 0; i < 7; ++i) if (button == buttons[i]) {
      if (down) physical_mask |= 1 << i; else physical_mask &= ~(1 << i);
    }
    if (composing || !capture.empty()) { ResetAim(); return; }
    InputEvent event; event.type = "aim"; event.button = button; event.down = down; Emit(event);
    if (button != config.cross_hold) return;
    const bool next = NextAim(aiming, aim_down, down, config.aim_toggle);
    aim_down = down;
    if (next != aiming) { aiming = next; }
  }
  void Compose() {
    if (composing) { EndCompose(); return; }
    if (!Allowed() || !quick_permitted || !config.quick_chat_allowed) return;
    QUERY_USER_NOTIFICATION_STATE state{};
    if (FAILED(SHQueryUserNotificationState(&state)) || state == QUNS_RUNNING_D3D_FULL_SCREEN ||
        !InteractiveDesktop()) {
      InputEvent event; event.type = "blocked"; event.text = "fullscreen_or_unavailable"; Emit(event); return;
    }
    ResetAim(); composing = true; composing_owner = config.owner; draft.clear(); Event("compose");
  }
  static LRESULT CALLBACK Keyboard(int code, WPARAM message, LPARAM data) {
    auto* self = current;
    if (code < 0 || !self || !self->Allowed()) return CallNextHookEx(nullptr, code, message, data);
    const auto& key = *reinterpret_cast<KBDLLHOOKSTRUCT*>(data);
    if (key.dwExtraInfo == remote::kRemoteInputExtraInfo) return CallNextHookEx(nullptr, code, message, data);
    if (GetForegroundWindow() != self->foreground) {
      self->foreground = GetForegroundWindow(); self->Retire();
    }
    if (!self->quick_permitted) self->EndCompose();
    const bool down = message == WM_KEYDOWN || message == WM_SYSKEYDOWN;
    if (EmergencyStop(key.vkCode, Down(VK_CONTROL), Down(VK_MENU), Down(VK_SHIFT))) {
      self->Retire(); return CallNextHookEx(nullptr, code, message, data);
    }
    if (key.vkCode >= 256) return CallNextHookEx(nullptr, code, message, data);
    self->physical_keys[key.vkCode] = down;
    const bool ctrl = self->physical_keys[VK_CONTROL] || self->physical_keys[VK_LCONTROL] || self->physical_keys[VK_RCONTROL];
    const bool alt = self->physical_keys[VK_MENU] || self->physical_keys[VK_LMENU] || self->physical_keys[VK_RMENU];
    const bool shift = self->physical_keys[VK_SHIFT] || self->physical_keys[VK_LSHIFT] || self->physical_keys[VK_RSHIFT];
    if (!down && self->swallowed[key.vkCode]) { self->swallowed[key.vkCode] = false; return 1; }
    const bool modifier = key.vkCode == VK_CONTROL || key.vkCode == VK_LCONTROL || key.vkCode == VK_RCONTROL ||
        key.vkCode == VK_SHIFT || key.vkCode == VK_LSHIFT || key.vkCode == VK_RSHIFT ||
        key.vkCode == VK_MENU || key.vkCode == VK_LMENU || key.vkCode == VK_RMENU ||
        key.vkCode == VK_LWIN || key.vkCode == VK_RWIN;
    if (key.vkCode == VK_SHIFT || key.vkCode == VK_LSHIFT || key.vkCode == VK_RSHIFT) self->Observe("shift", down);
    if (key.vkCode == VK_CONTROL || key.vkCode == VK_LCONTROL || key.vkCode == VK_RCONTROL) self->Observe("ctrl", down);
    if (modifier) return CallNextHookEx(nullptr, code, message, data);
    const bool win = self->physical_keys[VK_LWIN] || self->physical_keys[VK_RWIN];
    std::string combo = std::string(ctrl ? "Ctrl+" : "") + (alt ? "Alt+" : "") +
        (shift ? "Shift+" : "") + (win ? "Win+" : "");
    if ((key.vkCode >= 'A' && key.vkCode <= 'Z') || (key.vkCode >= '0' && key.vkCode <= '9')) combo += static_cast<char>(key.vkCode);
    else if (key.vkCode >= VK_F1 && key.vkCode <= VK_F24) combo += "F" + std::to_string(key.vkCode - VK_F1 + 1);
    else combo.clear();
    bool consume = false;
    if (down && !self->capture.empty()) {
      if (key.vkCode == VK_ESCAPE || ValidCombo(combo)) {
        InputEvent event; event.type = "capture"; event.action = self->capture;
        event.text = key.vkCode == VK_ESCAPE ? "" : combo; self->capture.clear(); self->Emit(event);
      }
      consume = true;
    } else if (down) {
      for (const auto& entry : self->config.hotkeys) {
        Combo binding;
        if (!Parse(entry.second, binding) || binding.key != key.vkCode || binding.ctrl != ctrl ||
            binding.alt != alt || binding.shift != shift || binding.win != win) continue;
        if (self->swallowed[key.vkCode]) { consume = true; break; }
        if (entry.first == "chat.quick") { const bool engaged = self->composing; self->Compose(); consume = engaged || self->composing; }
        else { InputEvent event; event.type = "hotkey"; event.action = entry.first; self->Emit(event); consume = true; }
        break;
      }
      if (!consume && self->composing) {
        consume = true;
        if (key.vkCode == VK_ESCAPE) self->EndCompose();
        else if (key.vkCode == VK_RETURN) {
          if (!self->draft.empty()) { InputEvent event; event.type = "submit"; event.text = Utf8(self->draft); self->Emit(event); self->draft.clear(); }
          self->Event("compose");
        } else {
          if (key.vkCode == VK_BACK && !self->draft.empty()) {
            const wchar_t last = self->draft.back(); self->draft.pop_back();
            if (last >= 0xdc00 && last <= 0xdfff && !self->draft.empty() && self->draft.back() >= 0xd800 && self->draft.back() <= 0xdbff) self->draft.pop_back();
          } else if (((!ctrl && !alt) || self->physical_keys[VK_RMENU]) && !win && self->draft.size() < kMaxDraft) {
            BYTE state[256]{}; GetKeyboardState(state);
            state[VK_SHIFT] = shift ? 0x80 : 0; state[VK_CONTROL] = ctrl ? 0x80 : 0; state[VK_MENU] = alt ? 0x80 : 0;
            wchar_t output[8]{};
            const auto layout = GetKeyboardLayout(GetWindowThreadProcessId(GetForegroundWindow(), nullptr));
            const int count = ToUnicodeEx(key.vkCode, key.scanCode, state, output, 8, 4, layout);
            if (count > 0 && self->draft.size() + static_cast<size_t>(count) <= kMaxDraft) self->draft.append(output, static_cast<size_t>(count));
          }
          InputEvent event; event.type = "compose"; event.text = Utf8(self->draft); self->Emit(event);
        }
      }
    }
    if (consume) { self->swallowed[key.vkCode] = true; return 1; }
    return CallNextHookEx(nullptr, code, message, data);
  }
  static LRESULT CALLBACK Mouse(int code, WPARAM message, LPARAM data) {
    auto* self = current;
    if (code < 0 || !self || !self->Allowed()) return CallNextHookEx(nullptr, code, message, data);
    const auto& value = *reinterpret_cast<MSLLHOOKSTRUCT*>(data);
    if (value.dwExtraInfo == remote::kRemoteInputExtraInfo) return CallNextHookEx(nullptr, code, message, data);
    if (GetForegroundWindow() != self->foreground) {
      self->foreground = GetForegroundWindow(); self->Retire();
    }
    const char* button = nullptr; bool down = false;
    switch (message) {
      case WM_LBUTTONDOWN: button = "left"; down = true; break;
      case WM_LBUTTONUP: button = "left"; break;
      case WM_RBUTTONDOWN: button = "right"; down = true; break;
      case WM_RBUTTONUP: button = "right"; break;
      case WM_MBUTTONDOWN: button = "middle"; down = true; break;
      case WM_MBUTTONUP: button = "middle"; break;
      case WM_XBUTTONDOWN: down = true; [[fallthrough]];
      case WM_XBUTTONUP: button = HIWORD(value.mouseData) == XBUTTON1 ? "x1" : "x2"; break;
    }
    if (button) self->Observe(button, down);
    return CallNextHookEx(nullptr, code, message, data);
  }
  void Poll() {
    Update();
    if (!Allowed()) return;
    const auto active = GetForegroundWindow();
    if (active != foreground) { foreground = active; Retire(); center_returns = 0; cursor_locked_until = 0; }
    if (!InteractiveDesktop()) { Retire(); return; }
    if (aim_down && !Down(HoldKey(config.cross_hold))) Observe(config.cross_hold, false);
    CURSORINFO cursor{sizeof(CURSORINFO)};
    if (!GetCursorInfo(&cursor)) return;
    RECT clip{}, rect{};
    const auto now = GetTickCount64();
    if (GetWindowRect(foreground, &rect)) {
      const bool center = std::abs(cursor.ptScreenPos.x - (rect.left + rect.right) / 2) <= 2 &&
          std::abs(cursor.ptScreenPos.y - (rect.top + rect.bottom) / 2) <= 2;
      if (last_cursor.x != LONG_MIN && center && (std::abs(cursor.ptScreenPos.x - last_cursor.x) > 8 || std::abs(cursor.ptScreenPos.y - last_cursor.y) > 8)) {
        center_returns = now - last_center < 500 ? center_returns + 1 : 1; last_center = now;
        if (center_returns >= 2) cursor_locked_until = now + 1500;
      }
    }
    // shortcut: cursor recentering is a heuristic until games expose a lock signal.
    const bool constrained = !GetClipCursor(&clip) || clip.left > GetSystemMetrics(SM_XVIRTUALSCREEN) ||
        clip.top > GetSystemMetrics(SM_YVIRTUALSCREEN) || clip.right < GetSystemMetrics(SM_XVIRTUALSCREEN) + GetSystemMetrics(SM_CXVIRTUALSCREEN) ||
        clip.bottom < GetSystemMetrics(SM_YVIRTUALSCREEN) + GetSystemMetrics(SM_CYVIRTUALSCREEN);
    InputEvent event; event.type = "cursor"; event.x = cursor.ptScreenPos.x; event.y = cursor.ptScreenPos.y;
    event.eligible = cursor.flags == CURSOR_SHOWING && !constrained && now >= cursor_locked_until;
    const int keys[] = {VK_LBUTTON, VK_RBUTTON, VK_MBUTTON, VK_XBUTTON1, VK_XBUTTON2, VK_SHIFT, VK_CONTROL};
    for (int i = 0; i < 7; ++i) if (!Down(keys[i])) physical_mask &= ~(1 << i);
    event.mask = physical_mask;
    const bool changed = event.x != last_cursor.x || event.y != last_cursor.y ||
        event.eligible != last_eligible || event.mask != last_mask;
    last_cursor = cursor.ptScreenPos;
    if (changed || now - last_cursor_event >= 500) {
      last_cursor_event = now; last_eligible = event.eligible; last_mask = event.mask; Emit(event);
    }
  }
  void Run() {
    current = this;
    MSG message{}; PeekMessageW(&message, nullptr, WM_USER, WM_USER, PM_NOREMOVE);
    const auto timer = SetTimer(nullptr, 0, 50, nullptr);
    if (!timer) { stopping = true; current = nullptr; SetEvent(ready); return; }
    thread_id = GetCurrentThreadId(); SetEvent(ready);
    while (GetMessageW(&message, nullptr, 0, 0) > 0) {
      if (message.message == kUpdate) Update();
      else if (message.message == WM_TIMER) Poll();
    }
    if (timer) KillTimer(nullptr, timer);
    Retire(); Hooks(false); current = nullptr; thread_id = 0;
  }
};
thread_local CompanionInput::Impl* CompanionInput::Impl::current = nullptr;
CompanionInput::CompanionInput(Sink sink) : impl_(std::make_unique<Impl>(std::move(sink))) {}
CompanionInput::~CompanionInput() { Stop(); }
bool CompanionInput::Configure(InputConfig config) {
  if (!impl_->thread_id || impl_->stopping) return false;
  if (config.owner.size() > 128 || config.hotkeys.size() > 128 ||
      (config.cross_hold != "off" && !HoldKey(config.cross_hold))) return false;
  for (const auto& entry : config.hotkeys) if (entry.first.empty() || entry.first.size() > 128 ||
      (!entry.second.empty() && !ValidCombo(entry.second))) return false;
  impl_->quick_permitted = config.quick_chat_allowed;
  impl_->permitted = config.enabled && impl_->connected;
  {
    std::lock_guard<std::mutex> lock(impl_->mutex);
    if (!config.enabled) impl_->cancel_requested = true;
    impl_->desired = std::move(config);
    ++impl_->config_generation;
  }
  impl_->Wake(); return true;
}
void CompanionInput::SetConnected(bool connected) {
  impl_->permitted = false;
  impl_->connected = connected;
  { std::lock_guard<std::mutex> lock(impl_->mutex); impl_->cancel_requested = true; }
  impl_->Wake();
}
bool CompanionInput::Capture(std::string action) {
  if (!impl_->Allowed() || action.empty() || action.size() > 128) return false;
  { std::lock_guard<std::mutex> lock(impl_->mutex); impl_->requested_capture = std::move(action); }
  impl_->Wake(); return true;
}
void CompanionInput::Cancel() {
  { std::lock_guard<std::mutex> lock(impl_->mutex); impl_->cancel_requested = true; }
  impl_->Wake();
}
void CompanionInput::Stop() {
  impl_->stopping = true; impl_->permitted = false; impl_->connected = false;
  const auto id = impl_->thread_id.load(); if (id) PostThreadMessageW(id, WM_QUIT, 0, 0);
  if (impl_->thread.joinable()) impl_->thread.join();
}
}  // namespace sybl::overlay
