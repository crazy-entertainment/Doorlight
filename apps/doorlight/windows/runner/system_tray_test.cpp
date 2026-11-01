#ifdef NDEBUG
#undef NDEBUG
#endif

#include "system_tray.h"

#include <cassert>
#include <stdexcept>
#include <string>
#include <thread>

#include "window_presentation.h"

namespace {

using sybl::window::RevealOperations;
using sybl::window::RunCoveredReveal;

RevealOperations Recording(std::string* order, bool cover_ok = true,
                           bool cover_throws = false,
                           bool finish_throws = false) {
  return RevealOperations{
      [=]() {
        *order += "cover,";
        if (cover_throws) throw std::runtime_error("cover");
        return cover_ok;
      },
      [=]() { *order += "show,"; },
      [=]() {
        *order += "finish,";
        if (finish_throws) throw std::runtime_error("finish");
      },
      [=]() { *order += "foreground,"; }};
}

// Test window that answers reveal requests exactly like FlutterWindow does:
// through DispatchRevealRequest with the shared operations.
int g_cover_calls = 0;
LRESULT CALLBACK RevealProc(HWND hwnd, UINT message, WPARAM wparam,
                            LPARAM lparam) {
  LRESULT result = 0;
  if (sybl::window::DispatchRevealRequest(
          message,
          sybl::window::WindowRevealOperations(
              hwnd, [] { ++g_cover_calls; return true; }, [] {}),
          &result)) {
    return result;
  }
  return DefWindowProcW(hwnd, message, wparam, lparam);
}

HWND CreateRevealWindow() {
  static bool registered = false;
  WNDCLASSW cls{};
  cls.lpfnWndProc = RevealProc;
  cls.hInstance = GetModuleHandleW(nullptr);
  cls.lpszClassName = L"SybLRevealTestWindow";
  if (!registered) {
    RegisterClassW(&cls);
    registered = true;
  }
  return CreateWindowExW(WS_EX_TOOLWINDOW | WS_EX_NOACTIVATE, cls.lpszClassName,
                         L"reveal", WS_OVERLAPPEDWINDOW, 0, 0, 200, 100,
                         nullptr, nullptr, cls.hInstance, nullptr);
}

void TestRevealSequence() {
  std::string order;
  assert(RunCoveredReveal(Recording(&order)));
  assert(order == "cover,show,finish,foreground,");

  order.clear();
  assert(!RunCoveredReveal(Recording(&order, /*cover_ok=*/false)));
  assert(order == "cover,");

  order.clear();
  assert(!RunCoveredReveal(Recording(&order, true, /*cover_throws=*/true)));
  assert(order == "cover,");

  order.clear();
  assert(!RunCoveredReveal(Recording(&order, true, false, /*finish=*/true)));
  assert(order == "cover,show,finish,");
}

void TestRevealRequestOnRealWindows() {
  const UINT request = sybl::window::RevealRequestMessage();
  assert(request != 0);

  HWND hidden = CreateRevealWindow();
  assert(hidden);
  assert(!IsWindowVisible(hidden));
  g_cover_calls = 0;
  assert(SendMessageW(hidden, request, 0, 0) == TRUE);
  assert(g_cover_calls == 1);
  assert(IsWindowVisible(hidden) && !IsIconic(hidden));

  ShowWindow(hidden, SW_MINIMIZE);
  assert(IsIconic(hidden));
  g_cover_calls = 0;
  assert(SendMessageW(hidden, request, 0, 0) == TRUE);
  assert(g_cover_calls == 1);
  assert(IsWindowVisible(hidden) && !IsIconic(hidden));
  DestroyWindow(hidden);

  // Commands never reveal a hidden window and never skip the cover for a
  // minimized one.
  HWND window = CreateRevealWindow();
  assert(!sybl::window::MinimizeWithoutReveal(window));
  assert(!IsWindowVisible(window));
  assert(!sybl::window::ToggleMaximizeWithoutReveal(window, [] { return true; }));
  assert(!IsWindowVisible(window));
  ShowWindow(window, SW_SHOWNOACTIVATE);
  assert(sybl::window::MinimizeWithoutReveal(window) && IsIconic(window));
  int reveals = 0;
  assert(!sybl::window::ToggleMaximizeWithoutReveal(
      window, [&] { ++reveals; return false; }));
  assert(reveals == 1 && IsIconic(window));
  assert(sybl::window::ToggleMaximizeWithoutReveal(window, [&] {
    ++reveals;
    ShowWindow(window, SW_RESTORE);
    return true;
  }));
  assert(reveals == 2 && IsZoomed(window));
  DestroyWindow(window);
}

// The tray owns no reveal logic: every restore path calls the one callback the
// owner installed and touches nothing else.
void TestTrayUsesOnlyOwnerReveal() {
  const UINT callback = RegisterWindowMessageW(
      L"Syb-L.Tray.Callback.4c6c0639-ceb8-477f-85ae-2cf31f3e82b2");
  assert(callback != 0);
  HWND window = CreateRevealWindow();
  assert(window && !IsWindowVisible(window));

  int calls = 0;
  bool result = true;
  bool throws = false;
  SystemTray tray;
  assert(tray.AttachForTest(window, [&] {
    ++calls;
    if (throws) throw std::runtime_error("reveal");
    return result;
  }));

  // Tray icon open, for every open notification.
  assert(tray.HandleWindowMessage(callback, 0, WM_LBUTTONUP));
  assert(calls == 1);
  assert(tray.HandleWindowMessage(callback, 0, NIN_SELECT));
  assert(calls == 2);
  // Menu Open.
  tray.HandleMenuCommand(SystemTray::kOpenCommand);
  assert(calls == 3);
  // Notifications that are not "open" never reveal.
  assert(tray.HandleWindowMessage(callback, 0, WM_MOUSEMOVE));
  tray.HandleMenuCommand(0);
  assert(calls == 3);
  // The tray never shows the window itself, whatever the callback returns.
  assert(!IsWindowVisible(window));

  result = false;
  tray.HandleMenuCommand(SystemTray::kOpenCommand);
  assert(calls == 4 && !IsWindowVisible(window));
  throws = true;
  assert(tray.HandleWindowMessage(callback, 0, WM_LBUTTONUP));
  assert(calls == 5 && !IsWindowVisible(window));
  throws = false;
  result = true;
  tray.Shutdown();

  // No reveal callback installed: nothing is shown.
  SystemTray unbound;
  assert(unbound.AttachForTest(window, nullptr));
  assert(unbound.HandleWindowMessage(callback, 0, WM_LBUTTONUP));
  unbound.HandleMenuCommand(SystemTray::kOpenCommand);
  assert(!IsWindowVisible(window));
  unbound.Shutdown();
  DestroyWindow(window);

  // Quit-failure fallback: DestroyWindow fails from a foreign thread, so the
  // tray falls back to the owner's reveal exactly once.
  HWND foreign = nullptr;
  DWORD thread_id = 0;
  HANDLE ready = CreateEventW(nullptr, TRUE, FALSE, nullptr);
  std::thread pump([&] {
    foreign = CreateRevealWindow();
    thread_id = GetCurrentThreadId();
    SetEvent(ready);
    MSG msg;
    while (GetMessageW(&msg, nullptr, 0, 0) > 0) DispatchMessageW(&msg);
  });
  WaitForSingleObject(ready, 5000);
  CloseHandle(ready);
  assert(foreign && IsWindow(foreign));
  int quit_calls = 0;
  SystemTray quitting;
  assert(quitting.AttachForTest(foreign, [&] { ++quit_calls; return true; }));
  quitting.HandleMenuCommand(SystemTray::kQuitCommand);
  assert(quit_calls == 1 && IsWindow(foreign));
  quitting.Shutdown();
  PostThreadMessageW(thread_id, WM_QUIT, 0, 0);
  pump.join();
}

}  // namespace

int main() {
  TestRevealSequence();
  TestRevealRequestOnRealWindows();
  TestTrayUsesOnlyOwnerReveal();
  using Activation = SystemTray::Activation;

  assert(SystemTray::ActivationForNotification(NIN_SELECT) ==
         Activation::kOpen);
  assert(SystemTray::ActivationForNotification(NIN_KEYSELECT) ==
         Activation::kOpen);
  assert(SystemTray::ActivationForNotification(WM_LBUTTONUP) ==
         Activation::kOpen);
  assert(SystemTray::ActivationForNotification(WM_LBUTTONDBLCLK) ==
         Activation::kOpen);
  assert(SystemTray::ActivationForNotification(WM_CONTEXTMENU) ==
         Activation::kMenu);
  assert(SystemTray::ActivationForNotification(WM_RBUTTONUP) ==
         Activation::kMenu);
  assert(SystemTray::ActivationForNotification(WM_MOUSEMOVE) ==
         Activation::kNone);

  SystemTray tray;
  assert(!tray.installed());
  assert(!tray.HideWindow());
  assert(!tray.HandleWindowMessage(WM_NULL, 0, 0));
  tray.Shutdown();
  tray.Shutdown();
}
