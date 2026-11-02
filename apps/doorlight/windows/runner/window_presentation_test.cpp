#include "win32_window.h"
#include "window_presentation.h"
#include <dwmapi.h>
#include <windowsx.h>
#include <cstdio>
#include <cstdlib>

#include <string>
#include <vector>

int failures = 0;
struct State {
  bool visible, zoomed, iconic, compact;
  WINDOWPLACEMENT placement;
  RECT rect;
  int mode;
};
bool Same(const State& a, const State& b) {
  return a.visible == b.visible && a.zoomed == b.zoomed && a.iconic == b.iconic &&
         a.compact == b.compact && a.mode == b.mode &&
         a.placement.showCmd == b.placement.showCmd &&
         EqualRect(&a.placement.rcNormalPosition, &b.placement.rcNormalPosition) &&
         EqualRect(&a.rect, &b.rect);
}
void Check(bool value, const char* label) {
  if (!value) { std::fprintf(stderr, "%s\n", label); ++failures; }
}

class RestoreWindow : public Win32Window {
 public:
  bool restore_allowed = true;
  bool restore_requested = false;
 protected:
  bool RevealMinimized(HWND window) noexcept override {
    restore_requested = true;
    return restore_allowed && Win32Window::RevealMinimized(window);
  }
};

class MeasuredWindow : public Win32Window {
 public:
  bool measure = false;
  std::vector<double> updates;
  std::vector<double> frames;
 protected:
  LRESULT MessageHandler(HWND window, UINT message, WPARAM wparam,
                         LPARAM lparam) noexcept override {
    if (measure && (message == WM_WINDOWPOSCHANGED ||
                   message == kWindowPresentationFrameMessage)) {
      LARGE_INTEGER now{}, frequency{};
      QueryPerformanceCounter(&now);
      QueryPerformanceFrequency(&frequency);
      auto& samples = message == WM_WINDOWPOSCHANGED ? updates : frames;
      samples.push_back(1000.0 * static_cast<double>(now.QuadPart) /
          static_cast<double>(frequency.QuadPart));
    }
    return Win32Window::MessageHandler(window, message, wparam, lparam);
  }
};

void CheckIcon(HWND hwnd, WPARAM kind, UINT dpi, int width_metric, int height_metric) {
  const auto icon = reinterpret_cast<HICON>(SendMessageW(hwnd, WM_GETICON, kind, 0));
  ICONINFO info{};
  Check(icon && GetIconInfo(icon, &info), "window supplies an explicit icon");
  BITMAP bitmap{};
  Check(info.hbmColor && GetObjectW(info.hbmColor, sizeof(bitmap), &bitmap) &&
      bitmap.bmWidth == GetSystemMetricsForDpi(width_metric, dpi) &&
      bitmap.bmHeight == GetSystemMetricsForDpi(height_metric, dpi),
      "window icon matches requested DPI metrics");
  if (info.hbmColor) DeleteObject(info.hbmColor);
  if (info.hbmMask) DeleteObject(info.hbmMask);
}

void PumpFor(DWORD milliseconds) {
  const ULONGLONG until = GetTickCount64() + milliseconds;
  do {
    MSG message{};
    while (PeekMessageW(&message, nullptr, 0, 0, PM_REMOVE)) {
      TranslateMessage(&message);
      DispatchMessageW(&message);
    }
    // Drain messages after every wait, including a wake past the deadline.
    if (GetTickCount64() >= until) break;
    // Wake for posted frames immediately; Sleep(1) can itself quantize this
    // synthetic message pump to the machine's default ~15ms timer resolution.
    MsgWaitForMultipleObjectsEx(0, nullptr, 1, QS_ALLINPUT, MWMO_INPUTAVAILABLE);
  } while (true);
}

int main() {
  SetProcessDpiAwarenessContext(DPI_AWARENESS_CONTEXT_PER_MONITOR_AWARE_V2);
  Check(sybl::window::MinimumTrackWidth(96, 8) == 296,
      "normal resize permits a 280 logical-pixel client");
  Check(sybl::window::MinimumTrackWidth(144, 12) == 444,
      "minimum scales with DPI and frame");
  Check(sybl::window::MinimumTrackWidth(0, 8) == 296,
      "missing DPI uses the standard logical minimum");
  using sybl::window::PresentationFrameDelay;
  Check(PresentationFrameDelay(0, 60) == 166667, "60 Hz initial deadline");
  Check(PresentationFrameDelay(0, 120) == 83334, "120 Hz initial deadline");
  Check(PresentationFrameDelay(0, 144) == 69445, "144 Hz initial deadline");
  Check(PresentationFrameDelay(20, 120) == 50000,
      "late frames skip missed deadlines without accumulating drift");
  Check(PresentationFrameDelay(219, 144) == 10000,
      "final frame lands at duration instead of next refresh interval");
  Check(PresentationFrameDelay(225, 120) == 1,
      "overdue completion never schedules a negative delay");
  Check(PresentationFrameDelay(0, 0) == PresentationFrameDelay(0, 60) &&
      PresentationFrameDelay(0, 1000) == PresentationFrameDelay(0, 60),
      "invalid display frequency falls back to 60 Hz");
  const SIZE scaled_default = sybl::window::DefaultWindowSize(144, RECT{-1200, 0, 1200, 1600});
  Check(scaled_default.cx == 1050 && scaled_default.cy == 750, "default scales with DPI");
  const SIZE clamped_default = sybl::window::DefaultWindowSize(144, RECT{-500, 20, 100, 420});
  Check(clamped_default.cx == 600 && clamped_default.cy == 400, "default clamps to small work area");
  const RECT small_work{-500, 20, 100, 420};
  Check(sybl::window::IsDefaultWindowSize({576, 376}, 144, small_work),
      "canonical gap-clamped default remains default on a small display");
  Check(sybl::window::IsDefaultWindowSize({592, 384}, 144, small_work,
          {8, 0, 8, 8}), "small-display default accounts for invisible frame");
  Check(!sybl::window::IsDefaultWindowSize({560, 360}, 144, small_work),
      "arbitrary small-display size still requires reset");
  Check(sybl::window::IsDefaultWindowSize({544, 336}, 144, small_work,
          {8, 0, 8, 8}, 24), "floating default uses DPI-scaled visible gap on a small display");
  for (const UINT dpi : {96u, 144u, 192u}) {
    for (const int logical_gap : {8, 24}) {
      const int gap = MulDiv(logical_gap, dpi, 96);
      const int frame = MulDiv(8, dpi, 96);
      const auto bounds = sybl::window::ChooseDefaultBounds(
          {-1600, 20, 0, 1080}, MulDiv(336, dpi, 96), MulDiv(368, dpi, 96),
          {frame, 0, frame, frame}, gap);
      Check(-bounds.x - bounds.width + frame == gap &&
          1080 - bounds.y - bounds.height + frame == gap,
          "both spacing choices follow DPI and invisible frame on a negative-origin monitor");
    }
  }
  const auto tiny_floating = sybl::window::ChooseDefaultBounds(
      {0, 0, 31, 21}, 700, 500, {8, 0, 8, 8}, 24);
  Check(tiny_floating.width > 0 && tiny_floating.height > 0 &&
      tiny_floating.x + 8 >= 0 && tiny_floating.y >= 0 &&
      31 - (tiny_floating.x + tiny_floating.width - 8) == 10 &&
      21 - (tiny_floating.y + tiny_floating.height - 8) == 10,
      "floating spacing caps safely on a tiny work area");
  const RECT normal_work{0, 0, 1920, 1080};
  Check(sybl::window::IsDefaultWindowSize({700, 504}, 96, normal_work),
      "near-default restored bounds keep the Compact action");
  Check(sybl::window::IsDefaultWindowSize({1044, 756}, 144, normal_work),
      "default tolerance scales with DPI in both directions");
  Check(!sybl::window::IsDefaultWindowSize({700, 505}, 96, normal_work) &&
      !sybl::window::IsDefaultWindowSize({1057, 750}, 144, normal_work),
      "bounds outside tolerance still offer Default size");
  {
    Win32Window docked;
    Check(docked.Create(L"Doorlight disposable corner test", {10, 10}, {700, 500}), "corner create");
    docked.SetDefaultCornerGap(8);
    docked.Show();
    RECT visible{}, work{};
    Check(SUCCEEDED(DwmGetWindowAttribute(docked.GetHandle(),
        DWMWA_EXTENDED_FRAME_BOUNDS, &visible, sizeof(visible))), "corner visible frame");
    Check(SystemParametersInfoW(SPI_GETWORKAREA, 0, &work, 0), "corner work area");
    const int gap = MulDiv(8, GetDpiForWindow(docked.GetHandle()), 96);
    Check(work.right - visible.right == gap && work.bottom - visible.bottom == gap,
        "shown visible frame has equal DPI-scaled 8px gaps");
    // Showing again must preserve a user's later position.
    SetWindowPos(docked.GetHandle(), nullptr, 100, 100, 0, 0,
        SWP_NOSIZE | SWP_NOZORDER | SWP_NOACTIVATE);
    docked.Show();
    RECT moved{};
    GetWindowRect(docked.GetHandle(), &moved);
    Check(moved.left == 100 && moved.top == 100, "corner placement applies only at startup");
  }
  {
    Win32Window spacing;
    Check(spacing.Create(L"Doorlight disposable edge spacing test", {100, 100}, {700, 500}),
        "edge spacing create");
    spacing.Show();
    const HWND handle = spacing.GetHandle();
    const auto has_gap = [&](int logical_gap) {
      DwmFlush();
      RECT visible{};
      MONITORINFO monitor{sizeof(MONITORINFO)};
      if (FAILED(DwmGetWindowAttribute(handle, DWMWA_EXTENDED_FRAME_BOUNDS,
              &visible, sizeof(visible))) ||
          !GetMonitorInfoW(MonitorFromWindow(handle, MONITOR_DEFAULTTONEAREST), &monitor))
        return false;
      const int gap = MulDiv(logical_gap, GetDpiForWindow(handle), 96);
      return monitor.rcWork.right - visible.right == gap &&
          monitor.rcWork.bottom - visible.bottom == gap;
    };
    RECT before{}, after{};
    GetWindowRect(handle, &before);
    Check(SendMessageW(handle, kWindowEdgeSpacingMessage, 24, 0),
        "bootstrap floating spacing accepted");
    GetWindowRect(handle, &after);
    Check(EqualRect(&before, &after), "bootstrap preserves restored placement and size");
    Check(!SendMessageW(handle, kWindowEdgeSpacingMessage, 16, 1) &&
        !SendMessageW(handle, kWindowEdgeSpacingMessage, 8, 2),
        "native message rejects unsupported gap and malformed reposition flag");
    Check(SendMessageW(handle, kWindowEdgeSpacingMessage, 24, 1) && has_gap(24),
        "floating preference reanchors visible expanded window");
    GetWindowRect(handle, &after);
    Check(after.right - after.left == before.right - before.left &&
        after.bottom - after.top == before.bottom - before.top,
        "spacing change preserves current size");
    Check(SendMessageW(handle, kWindowPresentationMessage, 1, 0) && has_gap(24),
        "fresh compact placement uses floating visible spacing");
    SetWindowPos(handle, nullptr, 140, 160, 0, 0,
        SWP_NOSIZE | SWP_NOZORDER | SWP_NOACTIVATE);
    GetWindowRect(handle, &before);
    SendMessageW(handle, kWindowPresentationMessage, 0, 2);
    Check(has_gap(24), "expanded default reset uses floating spacing");
    SendMessageW(handle, kWindowPresentationMessage, 1, 0);
    GetWindowRect(handle, &after);
    Check(EqualRect(&before, &after), "explicitly dragged compact placement survives ordinary expansion");
    SetWindowPos(handle, nullptr, 0, 0,
        after.right - after.left + 24, after.bottom - after.top + 32,
        SWP_NOMOVE | SWP_NOZORDER | SWP_NOACTIVATE);
    GetWindowRect(handle, &before);
    const SIZE resized_compact{before.right - before.left, before.bottom - before.top};
    Check(SendMessageW(handle, kWindowEdgeSpacingMessage, 8, 1) && has_gap(8),
        "close preference reanchors compact window and retires its old anchor");
    GetWindowRect(handle, &after);
    Check(after.right - after.left == resized_compact.cx &&
        after.bottom - after.top == resized_compact.cy,
        "compact spacing change preserves user-resized dimensions immediately");
    SendMessageW(handle, kWindowPresentationMessage, 0, 2);
    Check(has_gap(8), "expanded default reset uses close spacing");
    SendMessageW(handle, kWindowPresentationMessage, 1, 0);
    Check(has_gap(8), "next compact placement uses changed close spacing");
    GetWindowRect(handle, &after);
    Check(after.right - after.left == resized_compact.cx &&
        after.bottom - after.top == resized_compact.cy,
        "new compact anchor preserves user-resized dimensions through expand and compact");
    SetWindowPos(handle, nullptr, 120, 140, 0, 0,
        SWP_NOSIZE | SWP_NOZORDER | SWP_NOACTIVATE);
    ShowWindow(handle, SW_HIDE);
    GetWindowRect(handle, &before);
    Check(SendMessageW(handle, kWindowEdgeSpacingMessage, 24, 1),
        "hidden spacing change accepted without reveal");
    GetWindowRect(handle, &after);
    Check(!IsWindowVisible(handle) && EqualRect(&before, &after),
        "hidden spacing change preserves hidden geometry");
    spacing.Show();
    SendMessageW(handle, kWindowPresentationMessage, 0, 2);
    SendMessageW(handle, kWindowPresentationMessage, 1, 0);
    Check(has_gap(24), "hidden preference change does not recapture obsolete dragged compact anchor");
    SendMessageW(handle, kWindowPresentationMessage, 0, 1);
    Check(SendMessageW(handle, kWindowEdgeSpacingMessage, 8, 1) && has_gap(8) &&
        (SendMessageW(handle, kWindowPresentationStateMessage, 0, 0) & 4) == 0,
        "spacing change settles and cancels active animation");
    ShowWindow(handle, SW_MAXIMIZE);
    GetWindowRect(handle, &before);
    Check(SendMessageW(handle, kWindowEdgeSpacingMessage, 24, 1),
        "maximized spacing preference accepted");
    GetWindowRect(handle, &after);
    Check(IsZoomed(handle) && EqualRect(&before, &after),
        "spacing preference does not restore or resize maximized window");
  }
  {
    Win32Window reset;
    Check(reset.Create(L"Doorlight disposable reset test", {80, 80}, {800, 600}),
        "reset create");
    reset.Show();
    const HWND handle = reset.GetHandle();
    SetWindowPos(handle, HWND_TOPMOST, 160, 180, 800, 600, SWP_NOACTIVATE);
    const auto at_corner = [&]() {
      RECT visible{};
      MONITORINFO monitor{sizeof(MONITORINFO)};
      if (FAILED(DwmGetWindowAttribute(handle, DWMWA_EXTENDED_FRAME_BOUNDS,
              &visible, sizeof(visible))) ||
          !GetMonitorInfoW(MonitorFromWindow(handle, MONITOR_DEFAULTTONEAREST), &monitor))
        return false;
      const int gap = MulDiv(8, GetDpiForWindow(handle), 96);
      return monitor.rcWork.right - visible.right == gap &&
          monitor.rcWork.bottom - visible.bottom == gap &&
          SendMessageW(handle, kWindowPresentationStateMessage, 0, 0) == 2;
    };
    // lParam bit 1 resets position, bit 0 enables animation.
    Check(SendMessageW(handle, kWindowPresentationMessage, 0, 2) && at_corner(),
        "canonical reset restores size and visible corner gap");
    Check((GetWindowLongPtrW(handle, GWL_EXSTYLE) & WS_EX_TOPMOST) != 0,
        "canonical reset preserves pinning");
    SendMessageW(handle, kWindowPresentationMessage, 1, 0);
    SetWindowPos(handle, nullptr, 160, 180, 0, 0, SWP_NOSIZE | SWP_NOZORDER | SWP_NOACTIVATE);
    Check(SendMessageW(handle, kWindowPresentationMessage, 0, 3),
        "animated canonical reset from moved compact window accepted");
    // Completion and DWM bounds arrive asynchronously; a fixed sleep can leave
    // the last posted frame undelivered on a busy test host.
    const auto reset_deadline = GetTickCount64() + 1000;
    while (!at_corner() && GetTickCount64() < reset_deadline) PumpFor(1);
    Check(at_corner(), "animated reset ends at canonical placement");
    ShowWindow(handle, SW_MAXIMIZE);
    Check(SendMessageW(handle, kWindowPresentationMessage, 0, 2) && at_corner() &&
        !IsZoomed(handle), "canonical reset restores maximized window");
    SendMessageW(handle, kWindowPresentationMessage, 1, 0);
    ShowWindow(handle, SW_HIDE);
    RECT hidden{}, after_request{};
    GetWindowRect(handle, &hidden);
    Check(SendMessageW(handle, kWindowPresentationMessage, 0, 3),
        "hidden canonical reset accepted");
    GetWindowRect(handle, &after_request);
    Check(!IsWindowVisible(handle) && EqualRect(&hidden, &after_request),
        "hidden canonical reset leaves visibility and bounds untouched");
    reset.Show();
    Check(reset.ApplyDeferredPresentation() && at_corner(),
        "covered reveal retains deferred canonical position choice");
    SetWindowPos(handle, nullptr, 160, 180, 800, 600, SWP_NOZORDER | SWP_NOACTIVATE);
    Check(SendMessageW(handle, kWindowPresentationMessage, 0, 0),
        "remembered-position reset accepted");
    RECT remembered{};
    GetWindowRect(handle, &remembered);
    Check(remembered.left == 160 && remembered.top == 180,
        "remembered-position option retains previous position");
  }
  {
    const RECT start{0, 0, 700, 500}, end{100, 200, 436, 568};
    const RECT first = sybl::window::InterpolateBounds(start, end, 0);
    const RECT last = sybl::window::InterpolateBounds(start, end, 1);
    Check(EqualRect(&first, &start) && EqualRect(&last, &end), "animation exact endpoints");
    MeasuredWindow animated;
    Check(animated.Create(L"Doorlight disposable motion test", {80, 80}, {700, 500}), "animation create");
    animated.Show();
    const HWND handle = animated.GetHandle();
    SetWindowPos(handle, HWND_TOPMOST, 0, 0, 0, 0, SWP_NOMOVE | SWP_NOSIZE | SWP_NOACTIVATE);
    RECT before{}, begun{}, midway{}, retargeted{}, finished{};
    GetWindowRect(handle, &before);
    animated.measure = true;
    LARGE_INTEGER motion_started{}, motion_sampled{}, clock_frequency{};
    QueryPerformanceFrequency(&clock_frequency);
    QueryPerformanceCounter(&motion_started);
    Check(SendMessageW(handle, kWindowPresentationMessage, 1, 1), "animated compact accepted");
    GetWindowRect(handle, &begun);
    Check(EqualRect(&before, &begun), "animation starts without jumping");
    Check(SendMessageW(handle, kWindowPresentationStateMessage, 0, 0) == (1 | 4),
        "animated compact reports target layout and active animation");
    PumpFor(70);
    QueryPerformanceCounter(&motion_sampled);
    GetWindowRect(handle, &midway);
    animated.measure = false;
    const auto sampled_state = SendMessageW(handle, kWindowPresentationStateMessage, 0, 0);
    Check(!EqualRect(&midway, &before), "timer moves and resizes the window");
    Check(SendMessageW(handle, kWindowPresentationMessage, 0, 1), "midflight reversal accepted");
    GetWindowRect(handle, &retargeted);
    Check(EqualRect(&midway, &retargeted), "reversal starts at current geometry");
    Check(SendMessageW(handle, kWindowPresentationStateMessage, 0, 0) == (2 | 4),
        "animated expand reports target layout and active animation");
    PumpFor(300);
    GetWindowRect(handle, &finished);
    Check(EqualRect(&before, &finished), "reversal retains original normal placement");
    Check(SendMessageW(handle, kWindowPresentationStateMessage, 0, 0) == 2,
        "settled expansion clears active animation bit");
    // Log after reversal so output latency cannot affect its timing assertions.
    const double started_ms = 1000.0 * motion_started.QuadPart / clock_frequency.QuadPart;
    std::printf("initial presentation: elapsed=%.2f ms, frames=%zu, "
        "first dispatch=%.2f ms, geometry updates=%zu, state=%lld\n",
        1000.0 * (motion_sampled.QuadPart - motion_started.QuadPart) / clock_frequency.QuadPart,
        animated.frames.size(),
        animated.frames.empty() ? -1 : animated.frames.front() - started_ms,
        animated.updates.size(),
        static_cast<long long>(sampled_state));
    animated.frames.clear();
    animated.updates.clear();
    Check((GetWindowLongPtrW(handle, GWL_EXSTYLE) & WS_EX_TOPMOST) != 0, "animation preserves pinning");
    MONITORINFOEXW monitor{};
    monitor.cbSize = sizeof(monitor);
    DEVMODEW display{};
    display.dmSize = sizeof(display);
    GetMonitorInfoW(MonitorFromWindow(handle, MONITOR_DEFAULTTONEAREST), &monitor);
    EnumDisplaySettingsW(monitor.szDevice, ENUM_CURRENT_SETTINGS, &display);
    animated.measure = true;
    SendMessageW(handle, kWindowPresentationMessage, 1, 1);
    PumpFor(280);
    animated.measure = false;
    Check(SendMessageW(handle, kWindowPresentationStateMessage, 0, 0) == 1,
        "settled compact clears active animation bit");
    double min_interval = 1000, max_interval = 0, total_interval = 0;
    for (size_t i = 1; i < animated.updates.size(); ++i) {
      const double interval = animated.updates[i] - animated.updates[i - 1];
      min_interval = (std::min)(min_interval, interval);
      max_interval = (std::max)(max_interval, interval);
      total_interval += interval;
    }
    std::printf("presentation pacing: monitor=%lu Hz, HWND updates=%zu, "
        "interval min/mean/max=%.2f/%.2f/%.2f ms\n",
        display.dmDisplayFrequency, animated.updates.size(), min_interval,
        animated.updates.size() > 1
            ? total_interval / static_cast<double>(animated.updates.size() - 1) : 0,
        max_interval);
    Check(animated.updates.size() > 1, "frame scheduler produces intermediate HWND geometry");
    SendMessageW(handle, kWindowPresentationMessage, 0, 0);
    SendMessageW(handle, kWindowPresentationMessage, 1, 1);
    // A stalled UI owns at most one posted frame, and a previous animation's
    // frame cannot mutate geometry after a reversal.
    Sleep(60);
    MSG stale{}, extra{};
    Check(PeekMessageW(&stale, handle, kWindowPresentationFrameMessage,
        kWindowPresentationFrameMessage, PM_REMOVE), "frame posted while UI is stalled");
    Check(!PeekMessageW(&extra, handle, kWindowPresentationFrameMessage,
        kWindowPresentationFrameMessage, PM_REMOVE), "stalled UI has one outstanding frame");
    SendMessageW(handle, kWindowPresentationMessage, 0, 1);
    GetWindowRect(handle, &before);
    SendMessageW(handle, stale.message, stale.wParam, stale.lParam);
    GetWindowRect(handle, &finished);
    Check(EqualRect(&before, &finished), "stale frame ignored after reversal");
    PumpFor(280);
    SendMessageW(handle, kWindowPresentationMessage, 1, 1);
    PumpFor(35);
    SendMessageW(handle, WM_ENTERSIZEMOVE, 0, 0);
    GetWindowRect(handle, &before);
    PumpFor(260);
    GetWindowRect(handle, &finished);
    Check(EqualRect(&before, &finished), "manual resize cancels timer ownership");
    SendMessageW(handle, kWindowPresentationMessage, 0, 0);
    SendMessageW(handle, kWindowPresentationMessage, 1, 1);
    ShowWindow(handle, SW_HIDE);
    GetWindowRect(handle, &before);
    PumpFor(260);
    GetWindowRect(handle, &finished);
    Check(!IsWindowVisible(handle) && EqualRect(&before, &finished), "hide settles animation without revealing");
    Check(SendMessageW(handle, kWindowPresentationMessage, 0, 1), "hidden animated request defers");
    animated.Show();
    Check(animated.ApplyDeferredPresentation(), "deferred animation applies synchronously under cover");
    Check(SendMessageW(handle, kWindowPresentationStateMessage, 0, 0) == 2, "deferred default bounds applied");
    SetWindowPos(handle, nullptr, 160, 180, 800, 600, SWP_NOZORDER | SWP_NOACTIVATE);
    SendMessageW(handle, kWindowPresentationMessage, 0, 1);
    SendMessageW(handle, kWindowPresentationMessage, 1, 1);
    SendMessageW(handle, kWindowPresentationMessage, 0, 1);
    PumpFor(280);
    GetWindowRect(handle, &finished);
    Check(finished.left == 160 && finished.top == 180,
        "reset compact expand retains reset target position");
    SendMessageW(handle, kWindowPresentationMessage, 1, 1);
    animated.Destroy();
    PumpFor(240);
    Check(!IsWindow(handle), "destroy cancels animation timer");
  }
  RestoreWindow window;
  Check(window.Create(L"Doorlight disposable placement test", {80, 80}, {800, 600}), "create");
  const HWND hwnd = window.GetHandle();
  if (!hwnd) return 1;
  const auto check_minimum_width = [&](bool compact) {
    MINMAXINFO limits{};
    SendMessageW(hwnd, WM_GETMINMAXINFO, 0, reinterpret_cast<LPARAM>(&limits));
    const UINT dpi = GetDpiForWindow(hwnd);
    const int border = GetSystemMetricsForDpi(SM_CYFRAME, dpi) +
        GetSystemMetricsForDpi(SM_CXPADDEDBORDER, dpi);
    Check(limits.ptMinTrackSize.x == sybl::window::MinimumTrackWidth(dpi, border),
        compact ? "compact mode publishes narrow minimum" : "normal mode publishes narrow minimum");
  };
  check_minimum_width(false);
  CheckIcon(hwnd, ICON_SMALL, GetDpiForWindow(hwnd), SM_CXSMICON, SM_CYSMICON);
  CheckIcon(hwnd, ICON_BIG, GetDpiForWindow(hwnd), SM_CXICON, SM_CYICON);
  // Match the production first-frame Show(): pinning an unactivated test
  // window does not exercise the user-accessible application window.
  window.Show();
  const HWND child = CreateWindowExW(0, L"STATIC", L"", WS_CHILD | WS_VISIBLE | SS_NOTIFY,
      0, 0, 1, 1, hwnd, nullptr, GetModuleHandleW(nullptr), nullptr);
  Check(child != nullptr, "resize child create");
  Check(GetWindowThreadProcessId(child, nullptr) ==
      GetWindowThreadProcessId(hwnd, nullptr), "resize child shares parent UI thread");
  window.SetChildContent(child);
  RECT frame{};
  GetWindowRect(hwnd, &frame);
  const LONG middle = (frame.left + frame.right) / 2;
  for (const LONG x : {frame.left + 1, middle, frame.right - 1}) {
    const LPARAM point = MAKELPARAM(x, frame.top + 1);
    const LRESULT expected = x < middle ? HTTOPLEFT : x > middle ? HTTOPRIGHT : HTTOP;
    Check(SendMessageW(hwnd, WM_NCHITTEST, 0, point) == expected,
        "native top frame returns resize hit");
    Check(SendMessageW(child, WM_NCHITTEST, 0, point) == HTTRANSPARENT,
        "child yields top resize frame to native parent");
  }
  Check(SendMessageW(child, WM_NCHITTEST, 0,
      MAKELPARAM(middle, frame.top + 30)) == HTCLIENT,
      "child preserves title bar input below resize frame");
  ShowWindow(hwnd, SW_MAXIMIZE);
  GetWindowRect(hwnd, &frame);
  Check(SendMessageW(child, WM_NCHITTEST, 0,
      MAKELPARAM((frame.left + frame.right) / 2, frame.top + 1)) != HTTRANSPARENT,
      "maximized child does not expose a resize frame");
  ShowWindow(hwnd, SW_RESTORE);
  const auto at_default = [&]() {
    return SendMessageW(hwnd, kWindowPresentationStateMessage, 0, 0) == 2;
  };
  Check(!at_default(), "arbitrary normal size is not default");
  Check(SendMessageW(hwnd, kWindowPresentationMessage, 0, 0) && at_default(),
      "expand in normal mode resets arbitrary size to canonical default");
  WINDOWPLACEMENT before{sizeof(WINDOWPLACEMENT)};
  Check(GetWindowPlacement(hwnd, &before), "placement");
  Check(SetWindowPos(hwnd, HWND_TOPMOST, 0, 0, 0, 0,
      SWP_NOMOVE | SWP_NOSIZE | SWP_NOACTIVATE), "pin");
  Check((GetWindowLongPtrW(hwnd, GWL_EXSTYLE) & WS_EX_TOPMOST) != 0, "pin applied before transition");
  Check(SendMessageW(hwnd, kWindowPresentationMessage, 1, 0), "compact");
  check_minimum_width(true);
  Check(SendMessageW(hwnd, kWindowPresentationStateMessage, 0, 0) == 1,
      "restored compact reports compact layout");
  SendMessageW(hwnd, WM_SYSCOMMAND, SC_MAXIMIZE, 0);
  Check(IsZoomed(hwnd) && SendMessageW(hwnd, kWindowPresentationStateMessage, 0, 0) == 0,
      "native system maximize expands compact layout");
  SendMessageW(hwnd, WM_SYSCOMMAND, SC_RESTORE, 0);
  Check(SendMessageW(hwnd, kWindowPresentationStateMessage, 0, 0) == 1,
      "native system restore returns compact layout");
  Check((GetWindowLongPtrW(hwnd, GWL_EXSTYLE) & WS_EX_TOPMOST) != 0, "compact must preserve pin");
  RECT compact{};
  GetWindowRect(hwnd, &compact);
  MONITORINFO monitor{sizeof(MONITORINFO)};
  GetMonitorInfoW(MonitorFromWindow(hwnd, MONITOR_DEFAULTTONEAREST), &monitor);
  Check(compact.left >= monitor.rcWork.left && compact.top >= monitor.rcWork.top &&
        compact.right <= monitor.rcWork.right && compact.bottom <= monitor.rcWork.bottom, "work area");
  Check(SendMessageW(hwnd, kWindowPresentationMessage, 2, 0), "direct HUD");
  Check(SendMessageW(hwnd, kWindowPresentationMessage, 3, 0), "group HUD");
  RECT hud{};
  DwmFlush();
  Check(SUCCEEDED(DwmGetWindowAttribute(hwnd, DWMWA_EXTENDED_FRAME_BOUNDS,
      &hud, sizeof(hud))), "HUD visible frame available");
  const int margin = MulDiv(8, GetDpiForWindow(hwnd), 96);
  Check(hud.right == monitor.rcWork.right - margin &&
        hud.bottom == monitor.rcWork.bottom - margin, "HUD anchors visible bottom right with close spacing");
  Check(SendMessageW(hwnd, kWindowPresentationMessage, 1, 0), "conversation restore");
  RECT restored{};
  GetWindowRect(hwnd, &restored);
  Check(EqualRect(&restored, &compact), "independent conversation bounds");
  // An off-work-area DPI suggestion must be clamped without changing pin.
  RECT suggested{monitor.rcWork.right - 20, monitor.rcWork.bottom - 20,
      monitor.rcWork.right + 320, monitor.rcWork.bottom + 360};
  MONITORINFO dpi_monitor{sizeof(MONITORINFO)};
  GetMonitorInfoW(MonitorFromRect(&suggested, MONITOR_DEFAULTTONEAREST), &dpi_monitor);
  SendMessageW(hwnd, WM_DPICHANGED, MAKELONG(144, 144), reinterpret_cast<LPARAM>(&suggested));
  CheckIcon(hwnd, ICON_SMALL, 144, SM_CXSMICON, SM_CYSMICON);
  CheckIcon(hwnd, ICON_BIG, 144, SM_CXICON, SM_CYICON);
  RECT dpi_bounds{};
  GetWindowRect(hwnd, &dpi_bounds);
  Check(dpi_bounds.left >= dpi_monitor.rcWork.left && dpi_bounds.top >= dpi_monitor.rcWork.top &&
        dpi_bounds.right <= dpi_monitor.rcWork.right && dpi_bounds.bottom <= dpi_monitor.rcWork.bottom,
      "DPI work area clamp");
  Check(SendMessageW(hwnd, kWindowPresentationMessage, 0, 0), "expand");
  WINDOWPLACEMENT after{sizeof(WINDOWPLACEMENT)};
  GetWindowPlacement(hwnd, &after);
  Check(at_default(), "compact expansion resets canonical size");
  Check((GetWindowLongPtrW(hwnd, GWL_EXSTYLE) & WS_EX_TOPMOST) != 0, "expand must preserve pin");
  Check(!GetPropW(hwnd, kCompactWindowProperty), "normal persistence guard");
  ShowWindow(hwnd, SW_MAXIMIZE);
  Check(SendMessageW(hwnd, kWindowPresentationMessage, 1, 0), "compact from maximized");
  Check(!IsZoomed(hwnd), "compact restored");
  Check(SendMessageW(hwnd, kWindowPresentationMessage, 0, 0), "expand from previously maximized");
  Check(!IsZoomed(hwnd) && at_default(), "previous maximized placement resets to default");
  ShowWindow(hwnd, SW_RESTORE);
  WINDOWPLACEMENT unmaximized{sizeof(WINDOWPLACEMENT)};
  GetWindowPlacement(hwnd, &unmaximized);
  // The DPI move may have changed monitors; retain the position before maximize.
  if (!EqualRect(&after.rcNormalPosition, &unmaximized.rcNormalPosition)) {
    const RECT a = after.rcNormalPosition, b = unmaximized.rcNormalPosition;
    std::fprintf(stderr, "normal bounds before=(%ld,%ld,%ld,%ld) after=(%ld,%ld,%ld,%ld)\n",
        a.left, a.top, a.right, a.bottom, b.left, b.top, b.right, b.bottom);
  }
  Check(EqualRect(&after.rcNormalPosition, &unmaximized.rcNormalPosition),
        "restore after expand from maximized preserves normal bounds");
  ShowWindow(hwnd, SW_MAXIMIZE);
  Check(SendMessageW(hwnd, kWindowPresentationMessage, 0, 0) && at_default(),
      "maximized normal expansion resets canonical size");
  Check(SetWindowPos(hwnd, HWND_NOTOPMOST, 0, 0, 0, 0,
      SWP_NOMOVE | SWP_NOSIZE | SWP_NOACTIVATE), "unpin");
  Check(SendMessageW(hwnd, kWindowPresentationMessage, 1, 0), "unpinned compact");
  Check((GetWindowLongPtrW(hwnd, GWL_EXSTYLE) & WS_EX_TOPMOST) == 0, "compact must not pin");
  RECT before_compact_maximize{};
  GetWindowRect(hwnd, &before_compact_maximize);
  ShowWindow(hwnd, SW_MAXIMIZE);
  Check(SendMessageW(hwnd, kWindowPresentationMessage, 0, 0), "expand maximized compact");
  Check(SendMessageW(hwnd, kWindowPresentationMessage, 1, 0), "reenter after maximized compact");
  RECT after_compact_maximize{};
  GetWindowRect(hwnd, &after_compact_maximize);
  Check(EqualRect(&before_compact_maximize, &after_compact_maximize),
        "maximized compact must not overwrite its saved restored bounds");
  ShowWindow(hwnd, SW_HIDE);
  ShowWindow(hwnd, SW_SHOW);
  Check(GetPropW(hwnd, kCompactWindowProperty) != nullptr, "hide/reopen retains compact");
  Check(SendMessageW(hwnd, kWindowPresentationMessage, 0, 0), "unpinned expand");
  Check((GetWindowLongPtrW(hwnd, GWL_EXSTYLE) & WS_EX_TOPMOST) == 0, "expand must not pin");
  // Presentation commands on a hidden window change nothing; the latest one is
  // applied by the covered reveal, exactly as if it had been sent while visible.
  const auto send = [&](int mode) {
    return SendMessageW(hwnd, kWindowPresentationMessage, mode, 0) != 0;
  };
  const auto capture = [&]() {
    State state;
    state.visible = IsWindowVisible(hwnd) != FALSE;
    state.zoomed = IsZoomed(hwnd) != FALSE;
    state.iconic = IsIconic(hwnd) != FALSE;
    state.placement.length = sizeof(WINDOWPLACEMENT);
    GetWindowPlacement(hwnd, &state.placement);
    GetWindowRect(hwnd, &state.rect);
    state.compact = GetPropW(hwnd, kCompactWindowProperty) != nullptr;
    state.mode = window.presentation_mode();
    return state;
  };
  const auto reset = [&]() {
    ShowWindow(hwnd, SW_SHOW);
    send(0);
    ShowWindow(hwnd, SW_SHOWNORMAL);
  };
  const auto reveal = [&](std::string* order = nullptr, bool cover_ok = true) {
    return sybl::window::RunCoveredReveal(sybl::window::WindowRevealOperations(
        hwnd,
        [order, cover_ok] { if (order) *order += "cover,"; return cover_ok; },
        [order] { if (order) *order += "finish,"; },
        [&window, order] {
          if (order) *order += "apply,";
          window.ApplyDeferredPresentation();
        }));
  };
  // Runs |commands| on a hidden window that was first put in |setup|, checking
  // that nothing changes while hidden, and returns the state after reveal.
  const auto hidden_run = [&](void (*setup)(HWND), const std::vector<int>& commands,
                              const char* label) {
    reset();
    setup(hwnd);
    ShowWindow(hwnd, SW_HIDE);
    const State at_hide = capture();
    Check(!at_hide.visible, label);
    for (int mode : commands) {
      send(mode);
      Check(Same(at_hide, capture()), label);
    }
    Check(reveal(), label);
    return capture();
  };
  const auto maximize = [](HWND w) { ShowWindow(w, SW_MAXIMIZE); };
  const auto compact_maximized = [](HWND w) {
    ShowWindow(w, SW_MAXIMIZE);
    SendMessageW(w, kWindowPresentationMessage, 1, 0);
  };
  const auto none = [](HWND) {};

  // a. maximize -> hide -> mode 2 -> reveal
  reset();
  maximize(hwnd);
  send(2);
  const State visible_a = capture();
  const State hidden_a = hidden_run(maximize, {2}, "a: hidden mode 2 unchanged");
  Check(Same(visible_a, hidden_a) && hidden_a.mode == 2 && hidden_a.visible,
        "a: reveal applies mode 2 like visible");
  // b. maximize -> hide -> mode 1 -> mode 0 -> reveal ends at default size
  reset();
  maximize(hwnd);
  send(1);
  send(0);
  const State visible_b = capture();
  const State hidden_b = hidden_run(maximize, {1, 0}, "b: hidden commands unchanged");
  Check(Same(visible_b, hidden_b) && !hidden_b.zoomed && hidden_b.mode == 0 && at_default(),
        "b: ends at default size in normal mode");
  // c. maximize -> compact -> hide -> expand -> reveal ends at default size
  reset();
  compact_maximized(hwnd);
  send(0);
  const State visible_c = capture();
  const State hidden_c = hidden_run(compact_maximized, {0}, "c: hidden expand unchanged");
  Check(Same(visible_c, hidden_c) && !hidden_c.zoomed && hidden_c.mode == 0 && at_default(),
        "c: expand after hidden compact ends at default size");
  // e. only the last of several hidden commands is applied
  reset();
  send(2);
  const State visible_e = capture();
  const State hidden_e = hidden_run(none, {1, 3, 2}, "e: hidden commands unchanged");
  Check(Same(visible_e, hidden_e) && hidden_e.mode == 2, "e: last command wins");
  // f. no command while hidden: reveal applies nothing
  const State plain_reveal = hidden_run(maximize, {}, "f: nothing changes");
  Check(plain_reveal.zoomed && plain_reveal.mode == 0 && plain_reveal.visible,
        "f: reveal without command changes nothing");
  // A queued minimize can arrive after close-to-tray has hidden the window.
  reset();
  PostMessageW(hwnd, WM_SYSCOMMAND, SC_MINIMIZE, 0);
  ShowWindow(hwnd, SW_HIDE);
  const State before_late_minimize = capture();
  PumpFor(50);
  Check(Same(before_late_minimize, capture()),
        "late system minimize cannot reveal or change a hidden window");
  // A failed cover applies nothing and keeps the window hidden and unchanged.
  reset();
  ShowWindow(hwnd, SW_HIDE);
  const State failed_before = capture();
  send(2);
  Check(!reveal(nullptr, /*cover_ok=*/false), "failed cover reports failure");
  Check(Same(failed_before, capture()), "failed cover leaves hidden window unchanged");
  ShowWindow(hwnd, SW_SHOW);
  window.ApplyDeferredPresentation();
  Check(window.presentation_mode() == 2, "deferred mode survives a failed cover");
  // g. the deferred mode is applied between cover and finish
  reset();
  ShowWindow(hwnd, SW_HIDE);
  send(3);
  std::string order;
  Check(reveal(&order), "ordered reveal");
  Check(order == "cover,apply,finish,", "deferred mode applied under the cover");
  Check(window.presentation_mode() == 3 && IsWindowVisible(hwnd), "ordered reveal applied");
  // A hidden minimized window is restored by the reveal, then repositioned.
  reset();
  ShowWindow(hwnd, SW_MINIMIZE);
  ShowWindow(hwnd, SW_HIDE);
  const State minimized_at_hide = capture();
  send(1);
  Check(Same(minimized_at_hide, capture()), "hidden minimized window unchanged");
  Check(reveal(), "reveal hidden minimized");
  Check(IsWindowVisible(hwnd) && !IsIconic(hwnd) && window.presentation_mode() == 1,
        "hidden minimized reveal restores then applies");
  // A visible window still follows the command.
  reset();
  Check(send(1) && window.presentation_mode() == 1, "visible compact");
  Check(send(0), "visible expand");
  Check(IsWindowVisible(hwnd), "visible stays visible");
  ShowWindow(hwnd, SW_MINIMIZE);
  window.restore_allowed = false;
  Check(!send(0) && IsIconic(hwnd) && window.restore_requested,
      "failed covered restore leaves minimized window untouched");
  window.restore_allowed = true;
  Check(send(0) && !IsIconic(hwnd) && at_default(),
      "visible minimized expansion restores and resets default size");
  ShowWindow(hwnd, SW_MINIMIZE);
  window.restore_requested = false;
  window.restore_allowed = false;
  SendMessageW(hwnd, WM_SYSCOMMAND, SC_RESTORE, 0);
  Check(window.restore_requested && IsIconic(hwnd),
      "taskbar restore cannot bypass the owner's covered restore");
  window.restore_allowed = true;
  SendMessageW(hwnd, WM_SYSCOMMAND, SC_RESTORE, 0);
  Check(!IsIconic(hwnd), "taskbar restore completes through the owner");
  window.Destroy();
  if (failures == 0) std::puts("window_presentation_test: ok");
  return failures == 0 ? 0 : 1;
}
