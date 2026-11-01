// Optional controlled OS-delivery probe. Never register this program in CTest.
// Network identity, call state and local AllowOnce are synthetic test inputs.
// This does not prove libjami routing, Flutter transport, or physical consent.
#ifndef NOMINMAX
#define NOMINMAX
#endif
#include "remote_control_host.h"
#include "remote_control_win32_constants.h"
#include "screen_source.h"
#include "send_input_observer_test_support.h"

#include <windowsx.h>

#include <cstdio>
#include <map>
#include <memory>
#include <stdexcept>
#include <string>
#include <vector>

using namespace sybl::remote;
using sybl::remote::test::ScopedSendInputObserver;

namespace {

void Require(bool condition, const char* message) {
  if (!condition) throw std::runtime_error(message);
}

constexpr DWORD kPositionFlags = MOUSEEVENTF_MOVE | MOUSEEVENTF_ABSOLUTE |
    MOUSEEVENTF_VIRTUALDESK;
enum class MouseKind { invalid, move, down, up, cleanup };

MouseKind ClassifyMouse(const INPUT& input, bool held, bool inside) {
  if (input.type != INPUT_MOUSE || input.mi.dwExtraInfo != kRemoteInputExtraInfo ||
      input.mi.mouseData != 0) return MouseKind::invalid;
  const DWORD flags = input.mi.dwFlags;
  if (flags == MOUSEEVENTF_LEFTUP)
    return held ? MouseKind::cleanup : MouseKind::invalid;
  if (!inside || input.mi.dx < 0 || input.mi.dx > 65535 ||
      input.mi.dy < 0 || input.mi.dy > 65535) return MouseKind::invalid;
  if (flags == kPositionFlags) return MouseKind::move;
  if (flags == (kPositionFlags | MOUSEEVENTF_LEFTDOWN) && !held) return MouseKind::down;
  if (flags == (kPositionFlags | MOUSEEVENTF_LEFTUP) && held) return MouseKind::up;
  return MouseKind::invalid;
}

int TestMouseFlags() {
  INPUT input{};
  input.type = INPUT_MOUSE;
  input.mi.dwExtraInfo = kRemoteInputExtraInfo;
  input.mi.dx = input.mi.dy = 32768;
  for (const DWORD flags : {kPositionFlags, kPositionFlags | MOUSEEVENTF_LEFTDOWN,
                            kPositionFlags | MOUSEEVENTF_LEFTUP}) {
    input.mi.dwFlags = flags;
    const bool held = (flags & MOUSEEVENTF_LEFTUP) != 0;
    Require(ClassifyMouse(input, held, true) != MouseKind::invalid, "production flags rejected");
    Require(ClassifyMouse(input, held, false) == MouseKind::invalid, "outside target accepted");
    input.mi.dx = 65536;
    Require(ClassifyMouse(input, held, true) == MouseKind::invalid, "unbounded coordinate accepted");
    input.mi.dx = 32768;
    input.mi.dwFlags |= MOUSEEVENTF_RIGHTDOWN;
    Require(ClassifyMouse(input, held, true) == MouseKind::invalid, "extra flags accepted");
  }
  input.mi.dwFlags = kPositionFlags | MOUSEEVENTF_LEFTDOWN;
  Require(ClassifyMouse(input, true, true) == MouseKind::invalid, "duplicate down accepted");
  input.mi.dwFlags = kPositionFlags | MOUSEEVENTF_LEFTUP;
  Require(ClassifyMouse(input, false, true) == MouseKind::invalid, "unowned up accepted");
  input.mi.dwFlags = MOUSEEVENTF_LEFTDOWN;
  Require(ClassifyMouse(input, false, true) == MouseKind::invalid, "unpositioned press accepted");
  input.mi.dwFlags = MOUSEEVENTF_LEFTUP;
  Require(ClassifyMouse(input, true, false) == MouseKind::cleanup, "owed cleanup rejected");
  Require(ClassifyMouse(input, false, false) == MouseKind::invalid, "unowned cleanup accepted");
  input.mi.dwExtraInfo = 0;
  Require(ClassifyMouse(input, true, true) == MouseKind::invalid, "untagged input accepted");
  std::puts("Mouse admission flags passed; no OS input submitted.");
  return 0;
}

// AllowOnce needs no persistent write. Any unexpected persistence fails closed.
class EphemeralStorage final : public GrantBlobStorage {
 public:
  ReadResult Read() override { return {ReadStatus::kAbsent, {}}; }
  bool Write(const std::string&) override { return false; }
  bool Remove() override { return true; }
};

struct Receipt {
  UINT message;
  WPARAM value;
  LPARAM detail;
  ULONG_PTR extra;
};

struct Probe {
  HWND window = nullptr;
  HWND previous_foreground = GetForegroundWindow();
  POINT previous_cursor{};
  bool saved_cursor = GetCursorPos(&previous_cursor) != FALSE;
  bool armed = false;
  bool foreign_input = false;
  bool focus_lost = false;
  bool abort = false;
  HHOOK keyboard_hook = nullptr;
  HHOOK mouse_hook = nullptr;
  RemoteControlHost* host = nullptr;
  ScopedSendInputObserver::Function original = nullptr;
  std::vector<Receipt> receipts;
  std::map<WORD, INPUT> held_keys;
  std::map<WORD, INPUT> held_unicode;
  bool held_left = false;
  std::uint64_t remote_move_receipts = 0;
  std::uint64_t api_calls = 0;
  std::uint64_t sent_calls = 0;
  std::uint64_t pending_generation = 0;
  std::optional<GrantMessage> grant;
  std::string last_reason;
  std::string scenario;

  static inline Probe* current = nullptr;

  bool EmptyHolds() const {
    return held_keys.empty() && held_unicode.empty() && !held_left;
  }

  bool NoForeignHeldInput() const {
    for (int key = 1; key < 255; ++key) {
      if (held_keys.count(static_cast<WORD>(key)) != 0 ||
          (key == VK_LBUTTON && held_left) ||
          (key == VK_PACKET && !held_unicode.empty())) continue;
      if ((GetAsyncKeyState(key) & 0x8000) != 0) return false;
    }
    return true;
  }

  bool SafeForNewInput() {
    if (abort || foreign_input || focus_lost ||
        GetForegroundWindow() != window || GetFocus() != window ||
        !NoForeignHeldInput()) {
      abort = true;
      return false;
    }
    return true;
  }

  bool InClient(POINT point) const {
    RECT client{};
    if (!GetClientRect(window, &client)) return false;
    POINT local = point;
    if (!ScreenToClient(window, &local)) return false;
    // Keep all pointer input well inside the disposable client area.
    InflateRect(&client, -30, -30);
    return PtInRect(&client, local) && WindowFromPoint(point) == window;
  }

  UINT Observe(UINT count, LPINPUT inputs, int size) {
    ++api_calls;
    if (count != 1 || !inputs || size != sizeof(INPUT)) {
      abort = true;
      SetLastError(ERROR_INVALID_PARAMETER);
      return 0;
    }
    const INPUT input = *inputs;
    MouseKind mouse_kind = MouseKind::invalid;
    bool release = false;
    bool valid = false;
    if (input.type == INPUT_KEYBOARD &&
        input.ki.dwExtraInfo == kRemoteInputExtraInfo) {
      release = (input.ki.dwFlags & KEYEVENTF_KEYUP) != 0;
      if ((input.ki.dwFlags & KEYEVENTF_UNICODE) != 0) {
        valid = input.ki.wVk == 0 && input.ki.wScan == L'x' &&
            (input.ki.dwFlags & ~(KEYEVENTF_UNICODE | KEYEVENTF_KEYUP)) == 0 &&
            (release ? held_unicode.count(input.ki.wScan) != 0
                     : held_unicode.empty());
      } else {
        valid = input.ki.wVk >= 'A' && input.ki.wVk <= 'E' &&
            (input.ki.dwFlags & ~KEYEVENTF_KEYUP) == 0 &&
            (release ? held_keys.count(input.ki.wVk) != 0
                     : held_keys.count(input.ki.wVk) == 0);
      }
    } else if (input.type == INPUT_MOUSE &&
               input.mi.dwExtraInfo == kRemoteInputExtraInfo) {
      bool inside = false;
      if ((input.mi.dwFlags & kPositionFlags) == kPositionFlags &&
          input.mi.dx >= 0 && input.mi.dx <= 65535 &&
          input.mi.dy >= 0 && input.mi.dy <= 65535) {
        const int width = GetSystemMetrics(SM_CXVIRTUALSCREEN);
        const int height = GetSystemMetrics(SM_CYVIRTUALSCREEN);
        if (width > 1 && height > 1) {
          const POINT target{
              GetSystemMetrics(SM_XVIRTUALSCREEN) + MulDiv(input.mi.dx, width - 1, 65535),
              GetSystemMetrics(SM_YVIRTUALSCREEN) + MulDiv(input.mi.dy, height - 1, 65535)};
          inside = InClient(target);
        }
      }
      mouse_kind = ClassifyMouse(input, held_left, inside);
      valid = mouse_kind != MouseKind::invalid;
      release = mouse_kind == MouseKind::up || mouse_kind == MouseKind::cleanup;
    }
    // Only an accepted own down can authorize a release. Cleanup must remain
    // possible after focus loss. No new input can pass after a safety abort.
    // A positioned up also moves the pointer: only bare owed cleanup may
    // bypass the new-input gate after focus loss or a safety abort.
    if (!valid || ((!release || mouse_kind == MouseKind::up) && !SafeForNewInput())) {
      abort = true;
      std::printf("api blocked scenario=%s type=%lu release=%d valid=%d\n",
                  scenario.c_str(), input.type, release, valid);
      SetLastError(ERROR_ACCESS_DENIED);
      return 0;
    }
    SetLastError(ERROR_SUCCESS);
    const UINT result = original(count, inputs, size);
    const DWORD error = GetLastError();
    std::printf("api ms=%llu scenario=%s n=%llu type=%lu vk=%u scan=%u flags=%lu "
                "dx=%ld dy=%ld result=%u last_error=%lu foreground=%p\n",
                static_cast<unsigned long long>(GetTickCount64()),
                scenario.c_str(), static_cast<unsigned long long>(api_calls),
                input.type, input.type == INPUT_KEYBOARD ? input.ki.wVk : 0,
                input.type == INPUT_KEYBOARD ? input.ki.wScan : 0,
                input.type == INPUT_KEYBOARD ? input.ki.dwFlags : input.mi.dwFlags,
                input.type == INPUT_MOUSE ? input.mi.dx : 0,
                input.type == INPUT_MOUSE ? input.mi.dy : 0,
                result, error, static_cast<void*>(GetForegroundWindow()));
    if (result == 1) {
      ++sent_calls;
      if (input.type == INPUT_KEYBOARD) {
        auto& held = (input.ki.dwFlags & KEYEVENTF_UNICODE) != 0
            ? held_unicode : held_keys;
        const WORD key = (input.ki.dwFlags & KEYEVENTF_UNICODE) != 0
            ? input.ki.wScan : input.ki.wVk;
        if (release) held.erase(key);
        else held[key] = input;
      } else if (mouse_kind == MouseKind::down) {
        held_left = true;
      } else if (release) {
        held_left = false;
      }
    } else {
      abort = true;
    }
    SetLastError(error);
    return result;
  }

  static LRESULT CALLBACK KeyboardHook(int code, WPARAM wparam, LPARAM lparam) {
    if (code == HC_ACTION && current && current->armed) {
      const auto& event = *reinterpret_cast<KBDLLHOOKSTRUCT*>(lparam);
      if (!(event.flags & LLKHF_INJECTED) ||
          event.dwExtraInfo != kRemoteInputExtraInfo) current->foreign_input = true;
    }
    return CallNextHookEx(nullptr, code, wparam, lparam);
  }

  static LRESULT CALLBACK MouseHook(int code, WPARAM wparam, LPARAM lparam) {
    if (code == HC_ACTION && current && current->armed) {
      const auto& event = *reinterpret_cast<MSLLHOOKSTRUCT*>(lparam);
      if (!(event.flags & LLMHF_INJECTED) ||
          event.dwExtraInfo != kRemoteInputExtraInfo) {
        current->foreign_input = true;
      } else if (wparam == WM_MOUSEMOVE) {
        ++current->remote_move_receipts;
      }
    }
    return CallNextHookEx(nullptr, code, wparam, lparam);
  }

  static LRESULT CALLBACK WindowProc(HWND hwnd, UINT message,
                                     WPARAM wparam, LPARAM lparam) {
    Probe* probe = reinterpret_cast<Probe*>(GetWindowLongPtrW(hwnd, GWLP_USERDATA));
    if (message == WM_NCCREATE) {
      probe = static_cast<Probe*>(reinterpret_cast<CREATESTRUCTW*>(lparam)->lpCreateParams);
      SetWindowLongPtrW(hwnd, GWLP_USERDATA, reinterpret_cast<LONG_PTR>(probe));
    }
    if (probe) {
      if (message == WM_CLOSE) { probe->abort = true; return 0; }
      if (message == WM_KILLFOCUS && probe->armed) probe->focus_lost = true;
      if (message == WM_KEYDOWN || message == WM_KEYUP || message == WM_CHAR ||
          message == WM_MOUSEMOVE || message == WM_LBUTTONDOWN ||
          message == WM_LBUTTONUP) {
        const auto extra = static_cast<ULONG_PTR>(GetMessageExtraInfo());
        probe->receipts.push_back({message, wparam, lparam, extra});
        std::printf("receipt ms=%llu scenario=%s hwnd=%p message=%u value=%llu "
                    "x=%d y=%d extra=%llu\n",
                    static_cast<unsigned long long>(GetTickCount64()), probe->scenario.c_str(),
                    static_cast<void*>(hwnd), message,
                    static_cast<unsigned long long>(wparam),
                    GET_X_LPARAM(lparam), GET_Y_LPARAM(lparam),
                    static_cast<unsigned long long>(extra));
        return 0;  // The disposable window has no input-triggered actions.
      }
      if (probe->host && probe->host->HandleWindowMessage(message, wparam, lparam))
        return 0;
      if (message == WM_PAINT) {
        PAINTSTRUCT paint{};
        const auto dc = BeginPaint(hwnd, &paint);
        RECT client{};
        GetClientRect(hwnd, &client);
        SetBkMode(dc, TRANSPARENT);
        DrawTextW(dc, L"Syb-L controlled input probe\nDisposable test target\n"
                      L"Keep the mouse and keyboard still.\n"
                      L"Any local input stops this probe.", -1, &client,
                  DT_CENTER | DT_WORDBREAK);
        EndPaint(hwnd, &paint);
        return 0;
      }
    }
    return DefWindowProcW(hwnd, message, wparam, lparam);
  }

  void Pump() {
    MSG message{};
    while (PeekMessageW(&message, nullptr, 0, 0, PM_REMOVE)) {
      if (message.message == WM_QUIT) { abort = true; continue; }
      TranslateMessage(&message);
      DispatchMessageW(&message);
    }
  }

  template <class Predicate>
  void Wait(Predicate done, DWORD timeout_ms, const char* failure) {
    const auto deadline = GetTickCount64() + timeout_ms;
    do {
      Pump();
      Require(!abort && !foreign_input && !focus_lost, "safety abort during wait");
      if (done()) return;
      MsgWaitForMultipleObjectsEx(0, nullptr, 10, QS_ALLINPUT, MWMO_INPUTAVAILABLE);
    } while (GetTickCount64() < deadline);
    Require(false, failure);
  }

  bool Received(UINT message, WPARAM value, std::size_t from) const {
    for (auto i = from; i < receipts.size(); ++i) {
      const auto& receipt = receipts[i];
      if (receipt.message == message && receipt.value == value &&
          receipt.extra == kRemoteInputExtraInfo) return true;
    }
    return false;
  }

  bool ReceivedTranslatedText(WPARAM character, std::size_t from) const {
    if (abort || foreign_input || focus_lost) return false;
    bool packet_down = false;
    bool packet_up = false;
    bool text = false;
    for (auto i = from; i < receipts.size(); ++i) {
      const auto& receipt = receipts[i];
      if (receipt.value == VK_PACKET && receipt.extra == kRemoteInputExtraInfo) {
        if (receipt.message == WM_KEYDOWN) packet_down = true;
        if (receipt.message == WM_KEYUP && packet_down) packet_up = true;
      }
      // TranslateMessage does not preserve dwExtraInfo on WM_CHAR. Correlate
      // the exact character with tagged packet down/up in this bounded wait.
      if (receipt.message == WM_CHAR && receipt.value == character && packet_down)
        text = true;
    }
    return packet_down && packet_up && text;
  }

  void CreateTarget() {
    Require(NoForeignHeldInput(), "a physical key or mouse button is held at entry");
    current = this;
    WNDCLASSW cls{};
    cls.lpfnWndProc = WindowProc;
    cls.hInstance = GetModuleHandleW(nullptr);
    cls.hCursor = LoadCursor(nullptr, IDC_ARROW);
    cls.hbrBackground = reinterpret_cast<HBRUSH>(COLOR_WINDOW + 1);
    cls.lpszClassName = L"SyblControlledInputProbe";
    Require(RegisterClassW(&cls) != 0, "cannot register disposable window");
    POINT center{GetSystemMetrics(SM_CXSCREEN) / 2,
                 GetSystemMetrics(SM_CYSCREEN) / 2};
    window = CreateWindowExW(0, cls.lpszClassName, L"Syb-L input probe",
        WS_OVERLAPPED | WS_CAPTION | WS_SYSMENU, center.x - 320, center.y - 180,
        640, 360, nullptr, nullptr, cls.hInstance, this);
    Require(window != nullptr, "cannot create disposable window");
    ShowWindow(window, SW_SHOW);
    const BOOL foreground_requested = SetForegroundWindow(window);
    SetFocus(window);
    STARTUPINFOW startup{};
    startup.cb = sizeof(startup);
    GetStartupInfoW(&startup);
    std::printf("target_setup hwnd=%p visible=%d foreground_requested=%d "
                "foreground=%p focus=%p startup_flags=%lu startup_show=%u\n",
                static_cast<void*>(window), IsWindowVisible(window), foreground_requested,
                static_cast<void*>(GetForegroundWindow()), static_cast<void*>(GetFocus()),
                startup.dwFlags, startup.wShowWindow);
    Wait([&] { return GetForegroundWindow() == window && GetFocus() == window; },
         30000, "Windows did not give the disposable target foreground focus");
    Require(NoForeignHeldInput(), "a physical key or mouse button is held before arming");
    keyboard_hook = SetWindowsHookExW(WH_KEYBOARD_LL, KeyboardHook, cls.hInstance, 0);
    mouse_hook = SetWindowsHookExW(WH_MOUSE_LL, MouseHook, cls.hInstance, 0);
    Require(keyboard_hook && mouse_hook, "cannot install passive input safety hooks");
    armed = true;
    std::printf("target hwnd=%p previous_foreground=%p cursor=%ld,%ld\n",
                static_cast<void*>(window), static_cast<void*>(previous_foreground),
                previous_cursor.x, previous_cursor.y);
  }

  bool Cleanup() {
    // No new input after this point. The host must release its own holds first.
    abort = true;
    bool host_released = !host || host->Stop();
    for (int attempt = 0; !host_released && attempt < 20; ++attempt) {
      Pump();
      if (host) { host->PollSafety(); host_released = host->Stop(); }
      MsgWaitForMultipleObjectsEx(0, nullptr, 10, QS_ALLINPUT, MWMO_INPUTAVAILABLE);
    }
    // Emergency releases are cleanup only, and cannot make a failed host pass.
    Win32InputDesktopProbe desktop;
    if (!EmptyHolds() && original && desktop.Observe() == SafetyObservation::kSafe) {
      std::vector<INPUT> releases;
      for (const auto& item : held_keys) releases.push_back(item.second);
      for (const auto& item : held_unicode) releases.push_back(item.second);
      for (auto input : releases) {
        input.ki.dwFlags |= KEYEVENTF_KEYUP;
        Observe(1, &input, sizeof(INPUT));
      }
      if (held_left) {
        INPUT input{};
        input.type = INPUT_MOUSE;
        input.mi.dwFlags = MOUSEEVENTF_LEFTUP;
        input.mi.dwExtraInfo = kRemoteInputExtraInfo;
        Observe(1, &input, sizeof(INPUT));
      }
    }
    Pump();
    armed = false;
    if (keyboard_hook) UnhookWindowsHookEx(keyboard_hook);
    if (mouse_hook) UnhookWindowsHookEx(mouse_hook);
    keyboard_hook = mouse_hook = nullptr;
    // Do not replace a newer user focus/cursor choice after a safety abort.
    const bool can_restore = !foreign_input && !focus_lost &&
        window && GetForegroundWindow() == window;
    POINT restored_cursor{};
    const bool cursor_restored = can_restore && saved_cursor &&
        SetCursorPos(previous_cursor.x, previous_cursor.y) &&
        GetCursorPos(&restored_cursor) && restored_cursor.x == previous_cursor.x &&
        restored_cursor.y == previous_cursor.y;
    if (can_restore && IsWindow(previous_foreground)) SetForegroundWindow(previous_foreground);
    const bool focus_restored = can_restore &&
        GetForegroundWindow() == previous_foreground;
    std::printf("cleanup host_release=%d own_holds_empty=%d "
                "cursor_restored=%d focus_restored=%d foreign_input=%d focus_lost=%d\n",
                host_released, EmptyHolds(), cursor_restored, focus_restored,
                foreign_input, focus_lost);
    return host_released && EmptyHolds() && cursor_restored && focus_restored;
  }

  ~Probe() {
    armed = false;
    if (keyboard_hook) UnhookWindowsHookEx(keyboard_hook);
    if (mouse_hook) UnhookWindowsHookEx(mouse_hook);
    if (window) DestroyWindow(window);
    current = nullptr;
  }
};

struct DisplaySelection {
  HMONITOR target;
  int next = 0;
  std::optional<screen_source::Monitor> source;
};

BOOL CALLBACK SelectDisplay(HMONITOR monitor, HDC, LPRECT, LPARAM data) {
  auto& selection = *reinterpret_cast<DisplaySelection*>(data);
  const int index = selection.next++;
  MONITORINFO info{};
  info.cbSize = sizeof(info);
  if (monitor == selection.target && GetMonitorInfoW(monitor, &info)) {
    screen_source::Monitor source;
    source.index = index;
    source.left = info.rcMonitor.left;
    source.top = info.rcMonitor.top;
    source.width = info.rcMonitor.right - info.rcMonitor.left;
    source.height = info.rcMonitor.bottom - info.rcMonitor.top;
    selection.source = source;
  }
  return TRUE;
}

int Run() {
  Probe probe;
  EphemeralStorage storage;
  Win32GrantDpapiProtector protector;
  PersistentGrantStore grants(storage, protector);
  std::unique_ptr<RemoteControlHost> host;
  ScopedSendInputObserver observer([&](UINT count, LPINPUT inputs, int size) {
    return probe.Observe(count, inputs, size);
  });
  probe.original = observer.original();
  bool passed = false;
  try {
    probe.CreateTarget();
    DisplaySelection display{MonitorFromWindow(probe.window, MONITOR_DEFAULTTONULL)};
    Require(display.target != nullptr, "target has no display");
    EnumDisplayMonitors(nullptr, nullptr, SelectDisplay, reinterpret_cast<LPARAM>(&display));
    Require(display.source.has_value(), "cannot resolve target display");
    const auto source = *display.source;
    const auto uri = screen_source::DisplayMrl(source);
    Require(uri.has_value(), "cannot encode actual display MRL");
    std::printf("source uri=%s rect=%d,%d,%d,%d default_resolution=true\n",
                uri->c_str(), source.left, source.top, source.width, source.height);
    InboundControlEnvelope envelope;
    envelope.account_id = "synthetic-probe-local-account";
    envelope.controller_account = std::string(40, 'a');
    envelope.controller_device = std::string(64, '1');
    envelope.local_jami_id = std::string(40, 'b');
    envelope.source_uri = *uri;
    envelope.source_width = source.width;
    envelope.source_height = source.height;
    HostDependencies dependencies;
    dependencies.grants = &grants;  // All other dependencies use production defaults.
    host = std::make_unique<RemoteControlHost>(probe.window,
        [&](const std::string& call, const std::string& packet) {
          const auto parsed = ParsePacket(packet, WireDirection::kControlleeToController);
          if (!parsed || call != envelope.call_id) { probe.abort = true; return false; }
          if (const auto* value = std::get_if<GrantMessage>(&*parsed.message)) probe.grant = *value;
          std::printf("synthetic_sender scenario=%s message_variant=%zu\n",
                      probe.scenario.c_str(), parsed.message->index());
          return true;
        },
        [&](const std::string& type, const std::map<std::string, std::string>& fields) {
          std::printf("host_event scenario=%s type=%s", probe.scenario.c_str(), type.c_str());
          for (const auto& field : fields) {
            if (field.first == "state" || field.first == "reason" ||
                field.first == "releaseComplete" || field.first == "blocked" ||
                field.first == "hostGeneration" || field.first == "revokedThrough")
              std::printf(" %s=%s", field.first.c_str(), field.second.c_str());
          }
          std::printf("\n");
          if (type == "remoteControlRequest")
            probe.pending_generation = std::stoull(fields.at("hostGeneration"));
          if (const auto reason = fields.find("reason"); reason != fields.end())
            probe.last_reason = reason->second;
        },
        [&](const InboundControlEnvelope& value) {
          return value.account_id == envelope.account_id && value.call_id == envelope.call_id &&
              value.controller_account == envelope.controller_account &&
              value.controller_device == envelope.controller_device &&
              value.local_jami_id == envelope.local_jami_id &&
              value.source_uri == envelope.source_uri &&
              value.source_revision == envelope.source_revision &&
              value.source_width == envelope.source_width && value.source_height == envelope.source_height;
        }, dependencies);
    probe.host = host.get();
    std::uint64_t channel_epoch = 0;
    std::uint64_t revision = 0;
    std::uint64_t sequence = 0;
    const auto receive = [&](const Message& message) {
      const auto wire = SerializePacket(message, WireDirection::kControllerToControllee);
      Require(static_cast<bool>(wire), "cannot serialize synthetic packet");
      auto packet = envelope;
      packet.payload = wire.packet;
      host->OnControlMessage(std::move(packet));
    };
    const auto input = [&](std::vector<InputEvent> events) {
      Require(probe.grant.has_value(), "missing synthetic grant");
      receive(Message{InputMessage{probe.grant->token, probe.grant->epoch,
          ++sequence, envelope.source_revision, std::move(events)}});
    };
    const auto establish = [&](const char* name) {
      probe.Pump();
      Require(probe.SafeForNewInput() && probe.EmptyHolds(), "unsafe scenario entry");
      probe.scenario = name;
      envelope.call_id = std::string("synthetic-probe-") + name;
      ++envelope.source_revision;
      probe.grant.reset();
      probe.pending_generation = 0;
      sequence = 0;
      channel_epoch = host->ResetAuthorityChannel(true).channel_epoch;
      revision = 1;
      const auto permission = host->SetProtectedSurface(channel_epoch, revision, false);
      Require(!permission.blocked && permission.release_complete, "permission did not open");
      receive(Message{RequestMessage{static_cast<Capabilities>(
          CapabilityBit(Capability::kMouse) | CapabilityBit(Capability::kKeyboard) |
          CapabilityBit(Capability::kText)), envelope.source_revision}});
      Require(probe.pending_generation != 0, "host did not emit a synthetic consent request");
      const auto allowed = host->AllowOnce(envelope.call_id, envelope.controller_account,
          envelope.controller_device, envelope.source_revision, probe.pending_generation);
      Require(allowed == LocalControlResult::kApplied && probe.grant.has_value(),
              "default Windows safety checks did not permit activation");
      probe.Pump();
      Require(host->AuthorityStatus().state == "active", "host did not remain active");
      std::printf("scenario_begin name=%s synthetic_allow_once=true\n", name);
    };
    const auto verify_release = [&](WORD key, std::size_t from) {
      probe.Wait([&] {
        return probe.Received(WM_KEYUP, key, from) &&
            probe.Received(WM_LBUTTONUP, 0, from) &&
            (GetAsyncKeyState(key) & 0x8000) == 0 &&
            (GetAsyncKeyState(VK_LBUTTON) & 0x8000) == 0;
      }, 700, "target did not receive held-input releases");
      const auto status = host->AuthorityStatus();
      Require(status.state == "inactive" && status.release_complete &&
              status.revoked_through != 0 && probe.EmptyHolds(),
              "native revocation was not acknowledged");
      const auto calls_after_ack = observer.calls();
      const auto receipts_after_ack = probe.receipts.size();
      input({KeyEvent{'E', true}, TextEvent{"x"}, ButtonEvent{MouseButton::kLeft, true}});
      const auto deadline = GetTickCount64() + 200;
      probe.Wait([&] { return GetTickCount64() >= deadline; }, 400, "late-input observation timeout");
      bool late_input = false;
      for (auto i = receipts_after_ack; i < probe.receipts.size(); ++i) {
        const auto& receipt = probe.receipts[i];
        // Windows can post an untagged mouse-position message after a window
        // update without an input submission. All tagged input and all other
        // key, text and button receipts still fail this check.
        late_input |= receipt.message != WM_MOUSEMOVE || receipt.extra != 0;
      }
      Require(observer.calls() == calls_after_ack && !late_input,
              "stale input reached the OS boundary or target after acknowledgement");
      std::printf("scenario_pass name=%s key_up_received=true button_up_received=true "
                  "async_key_up=true async_button_up=true no_calls_after_ack=true\n",
                  probe.scenario.c_str());
    };
    const auto move_to_target = [&] {
      RECT client{};
      Require(GetClientRect(probe.window, &client) != FALSE, "target client is unavailable");
      POINT point{(client.right - client.left) / 2, (client.bottom - client.top) / 2};
      Require(ClientToScreen(probe.window, &point) != FALSE, "cannot resolve target point");
      POINT before{};
      Require(GetCursorPos(&before) != FALSE, "cannot read the current cursor position");
      // A move to the current pixel need not produce a tagged WM_MOUSEMOVE.
      // Keep a real displacement inside this target for every scenario.
      if (before.x >= point.x - 10 && before.x <= point.x + 10) point.x += 40;
      Require(probe.InClient(point), "the displaced point is outside the target");
      POINT expected_client = point;
      Require(ScreenToClient(probe.window, &expected_client) != FALSE,
              "cannot resolve the expected client point");
      const auto moves_before = probe.remote_move_receipts;
      const auto from = probe.receipts.size();
      input({MoveEvent{static_cast<double>(point.x - source.left) / (source.width - 1),
                       static_cast<double>(point.y - source.top) / (source.height - 1)}});
      probe.Wait([&] {
        POINT cursor{};
        bool received = false;
        for (auto i = from; i < probe.receipts.size(); ++i)
          received |= probe.receipts[i].message == WM_MOUSEMOVE &&
              std::abs(GET_X_LPARAM(probe.receipts[i].detail) - expected_client.x) <= 1 &&
              std::abs(GET_Y_LPARAM(probe.receipts[i].detail) - expected_client.y) <= 1;
        // Mouse moves can be coalesced with untagged window updates. Require
        // the tagged OS hook event, the target's exact position receipt and
        // the actual cursor position; foreign input still aborts the wait.
        return probe.remote_move_receipts > moves_before && received &&
            GetCursorPos(&cursor) && probe.InClient(cursor) &&
            std::abs(cursor.x - point.x) <= 1 && std::abs(cursor.y - point.y) <= 1;
      }, 700, "target did not receive a real mouse move");
      std::printf("move_pass scenario=%s tagged_os_hook=true target_position=true cursor_position=true\n",
                  probe.scenario.c_str());
    };
    const auto hold = [&](WORD key) {
      move_to_target();
      const auto from = probe.receipts.size();
      input({KeyEvent{key, true}, ButtonEvent{MouseButton::kLeft, true}});
      probe.Wait([&] {
        return probe.Received(WM_KEYDOWN, key, from) &&
            probe.Received(WM_LBUTTONDOWN, MK_LBUTTON, from) &&
            (GetAsyncKeyState(key) & 0x8000) != 0 &&
            (GetAsyncKeyState(VK_LBUTTON) & 0x8000) != 0;
      }, 700, "target did not receive held key and mouse input");
      return from;
    };

    establish("key-text-click");
    auto from = probe.receipts.size();
    input({KeyEvent{'A', true}, KeyEvent{'A', false}, TextEvent{"x"}});
    probe.Wait([&] {
      return probe.Received(WM_KEYDOWN, 'A', from) && probe.Received(WM_KEYUP, 'A', from) &&
          probe.ReceivedTranslatedText('x', from) && (GetAsyncKeyState('A') & 0x8000) == 0;
    }, 700, "target did not receive key down/up and Unicode text");
    move_to_target();
    from = probe.receipts.size();
    input({ButtonEvent{MouseButton::kLeft, true}, ButtonEvent{MouseButton::kLeft, false}});
    probe.Wait([&] {
      return probe.Received(WM_LBUTTONDOWN, MK_LBUTTON, from) &&
          probe.Received(WM_LBUTTONUP, 0, from) &&
          (GetAsyncKeyState(VK_LBUTTON) & 0x8000) == 0;
    }, 700, "target did not receive a real click");
    Require(host->Stop() && probe.EmptyHolds(), "normal stop did not complete");
    std::printf("scenario_pass name=key-text-click actual_key_text_move_click=true\n");

    establish("held-stop");
    from = hold('B');
    Require(host->Stop(), "held-input Stop did not acknowledge release");
    verify_release('B', from);

    establish("protected-surface");
    from = hold('C');
    const auto blocked = host->SetProtectedSurface(channel_epoch, ++revision, true);
    Require(blocked.blocked && blocked.release_complete, "protected-surface block did not acknowledge");
    verify_release('C', from);

    establish("channel-reset");
    from = hold('D');
    const auto reset = host->ResetAuthorityChannel(false);
    Require(reset.blocked && reset.release_complete, "channel reset did not acknowledge");
    verify_release('D', from);

    establish("lease-expiry");
    from = hold('E');
    probe.last_reason.clear();
    probe.Wait([&] { return host->AuthorityStatus().state == "inactive"; },
               2200, "real 1500 ms permission lease did not expire");
    Require(probe.last_reason == "lease-expired", "revocation reason was not lease expiry");
    verify_release('E', from);
    Require(probe.api_calls == probe.sent_calls && !probe.abort,
            "one or more observed API calls failed or were blocked");
    passed = true;
  } catch (const std::exception& error) {
    std::fprintf(stderr, "probe_failed scenario=%s reason=%s\n",
                 probe.scenario.c_str(), error.what());
  }
  const bool clean = probe.Cleanup();
  if (host) host->Shutdown();
  probe.host = nullptr;
  host.reset();
  std::printf("probe_result pass=%d api_calls=%llu successful_calls=%llu "
              "default_host=true default_adapter=true real_os_probes=true "
              "synthetic_authority=true physical_consent_proven=false libjami_proven=false\n",
              passed && clean, static_cast<unsigned long long>(probe.api_calls),
              static_cast<unsigned long long>(probe.sent_calls));
  return passed && clean ? 0 : 1;
}

}  // namespace

int main(int argc, char** argv) {
  std::setvbuf(stdout, nullptr, _IONBF, 0);
  if (argc == 2 && std::string(argv[1]) == "--test-mouse-flags") {
    try { return TestMouseFlags(); }
    catch (const std::exception& error) { std::fprintf(stderr, "%s\n", error.what()); return 1; }
  }
  wchar_t executable[32768]{};
  const DWORD path_length = GetModuleFileNameW(nullptr, executable, 32768);
  if (path_length == 0 || path_length >= 32768) return 2;
  std::printf("probe_process pid=%lu path=%ls\n", GetCurrentProcessId(), executable);
  std::puts("Optional RC6 controlled Windows input probe. No real peer or physical consent proof.");
  if (argc != 2 || std::string(argv[1]) != "--send-real-input") {
    std::puts("No input sent. Explicit opt-in: rc6_windows_input_probe.exe --send-real-input");
    return 2;
  }
  // The standalone process uses physical desktop coordinates throughout.
  if (!SetProcessDpiAwarenessContext(DPI_AWARENESS_CONTEXT_PER_MONITOR_AWARE_V2)) {
    std::fprintf(stderr, "probe_failed reason=cannot_set_per_monitor_dpi error=%lu\n", GetLastError());
    return 1;
  }
  return Run();
}
