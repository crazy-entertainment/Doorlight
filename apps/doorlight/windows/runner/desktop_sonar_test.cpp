#include "desktop_sonar.h"

#include <cassert>
#include <cmath>
#include <limits>

namespace {
HWND watched_overlay = nullptr;
bool overlay_activated = false;

void CALLBACK ForegroundChanged(HWINEVENTHOOK, DWORD, HWND window,
                                LONG, LONG, DWORD, DWORD) {
  if (window == watched_overlay) overlay_activated = true;
}

void PumpMessages() {
  MSG message{};
  while (PeekMessageW(&message, nullptr, 0, 0, PM_REMOVE)) {
    TranslateMessage(&message);
    DispatchMessageW(&message);
  }
}
}  // namespace

int main() {
  using sybl::sonar::DesktopSonar;
  using sybl::sonar::IsValidReveal;
  static_assert(sybl::sonar::kDurationMs <= 1250);
  static_assert(sybl::sonar::kWindowStyles == 0x080800a8);
  assert(IsValidReveal(0, 0, 0));
  assert(IsValidReveal(16384, 16384, 0xffffff));
  assert(!IsValidReveal(-1, 0, 0));
  assert(!IsValidReveal(0, std::numeric_limits<double>::infinity(), 0));
  assert(!IsValidReveal(0, 0, 0x1000000));
  assert(!IsValidReveal(0, 0, 0x010203));
  DesktopSonar sonar;
  sonar.Cancel();
  HWND owner = CreateWindowExW(WS_EX_NOACTIVATE | WS_EX_TOOLWINDOW, L"STATIC",
      L"", WS_POPUP, 0, 0, 32, 32, nullptr, nullptr, GetModuleHandleW(nullptr), nullptr);
  assert(owner);
  ShowWindow(owner, SW_SHOWNOACTIVATE);
  // Other apps may receive focus during the wait; only sonar activation fails.
  const HWINEVENTHOOK focus_hook = SetWinEventHook(
      EVENT_SYSTEM_FOREGROUND, EVENT_SYSTEM_FOREGROUND, nullptr,
      ForegroundChanged, GetCurrentProcessId(), GetCurrentThreadId(),
      WINEVENT_OUTOFCONTEXT);
  assert(focus_hook);
  assert(sonar.Reveal(owner, 10, 10, 0xe4bc70));
  HWND overlay = FindWindowW(L"SybLDesktopSonar", nullptr);
  assert(overlay);
  watched_overlay = overlay;
  assert((GetWindowLongPtrW(overlay, GWL_EXSTYLE) & sybl::sonar::kWindowStyles) == sybl::sonar::kWindowStyles);
  assert(SendMessageW(overlay, WM_NCHITTEST, 0, 0) == HTTRANSPARENT);
  assert(GetForegroundWindow() != overlay);
  const ULONGLONG started = GetTickCount64();
  while (GetTickCount64() - started < 1500) {
    PumpMessages();
    Sleep(10);
  }
  assert(!IsWindow(overlay));
  assert(!overlay_activated);
  assert(sonar.Reveal(owner, 10, 10, 0xe4bc70));
  overlay = FindWindowW(L"SybLDesktopSonar", nullptr);
  assert(overlay);
  watched_overlay = overlay;
  assert(GetForegroundWindow() != overlay);
  ShowWindow(owner, SW_HIDE);
  SendMessageW(overlay, WM_TIMER, 1, 0);
  assert(!IsWindow(overlay));
  PumpMessages();
  assert(!overlay_activated);
  assert(UnhookWinEvent(focus_hook));
  DestroyWindow(owner);
}
