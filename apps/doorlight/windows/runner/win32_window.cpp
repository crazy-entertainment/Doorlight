#include "win32_window.h"
#include "window_presentation.h"
#include "window_bounds.h"
#include <algorithm>

#include <dwmapi.h>
#include <commctrl.h>
#include <flutter_windows.h>
#include <windowsx.h>

#include "resource.h"

namespace {

/// Window attribute that enables dark mode window decorations.
///
/// Redefined in case the developer's machine has a Windows SDK older than
/// version 10.0.22000.0.
/// See: https://docs.microsoft.com/windows/win32/api/dwmapi/ne-dwmapi-dwmwindowattribute
#ifndef DWMWA_USE_IMMERSIVE_DARK_MODE
#define DWMWA_USE_IMMERSIVE_DARK_MODE 20
#endif

#ifndef DWMWA_WINDOW_CORNER_PREFERENCE
#define DWMWA_WINDOW_CORNER_PREFERENCE 33
#endif

#ifndef DWMWA_BORDER_COLOR
#define DWMWA_BORDER_COLOR 34
#endif

#ifndef DWMWA_COLOR_NONE
#define DWMWA_COLOR_NONE 0xFFFFFFFE
#endif

constexpr const wchar_t kWindowClassName[] = L"FLUTTER_RUNNER_WIN32_WINDOW";
constexpr DWORD kWindowStyle = WS_OVERLAPPEDWINDOW & ~WS_CAPTION;

LRESULT CALLBACK ResizeFrameSubclass(HWND hwnd, UINT message, WPARAM wparam,
                                    LPARAM lparam, UINT_PTR id, DWORD_PTR) {
  if (message == WM_NCHITTEST) {
    const LRESULT hit = SendMessageW(GetParent(hwnd), message, wparam, lparam);
    // The full-bleed Flutter child covers the native top resize frame.
    if (hit >= HTLEFT && hit <= HTBOTTOMRIGHT) return HTTRANSPARENT;
  } else if (message == WM_NCDESTROY) {
    RemoveWindowSubclass(hwnd, ResizeFrameSubclass, id);
  }
  return DefSubclassProc(hwnd, message, wparam, lparam);
}
// ponytail: Win32 must answer before Dart lays out the window. Keep this
// stable floor in sync only if the 34dp chrome or 58dp header/1dp divider/68dp
// composer minima change; use a native metrics channel only if those sizes
// become configurable.
constexpr int kMinimumClientHeightDip = 34 + 58 + 1 + 68;

constexpr LONG MinimumTrackHeight(UINT dpi, LONG resize_border) {
  const auto client_height =
      (static_cast<long long>(kMinimumClientHeightDip) * dpi +
       USER_DEFAULT_SCREEN_DPI - 1) /
      USER_DEFAULT_SCREEN_DPI;
  return static_cast<LONG>(client_height + 2 * resize_border);
}

static_assert(MinimumTrackHeight(96, 8) == 177);
static_assert(MinimumTrackHeight(120, 10) == 222);
static_assert(MinimumTrackHeight(144, 12) == 266);

/// Registry key for app theme preference.
///
/// A value of 0 indicates apps should use dark mode. A non-zero or missing
/// value indicates apps should use light mode.
constexpr const wchar_t kGetPreferredBrightnessRegKey[] =
  L"Software\\Microsoft\\Windows\\CurrentVersion\\Themes\\Personalize";
constexpr const wchar_t kGetPreferredBrightnessRegValue[] = L"AppsUseLightTheme";

// The number of Win32Window objects that currently exist.
static int g_active_window_count = 0;

using EnableNonClientDpiScaling = BOOL __stdcall(HWND hwnd);

// Scale helper to convert logical scaler values to physical using passed in
// scale factor
int Scale(int source, double scale_factor) {
  return static_cast<int>(source * scale_factor);
}

// Dynamically loads the |EnableNonClientDpiScaling| from the User32 module.
// This API is only needed for PerMonitor V1 awareness mode.
void EnableFullDpiSupportIfAvailable(HWND hwnd) {
  HMODULE user32_module = LoadLibraryA("User32.dll");
  if (!user32_module) {
    return;
  }
  auto enable_non_client_dpi_scaling =
      reinterpret_cast<EnableNonClientDpiScaling*>(
          GetProcAddress(user32_module, "EnableNonClientDpiScaling"));
  if (enable_non_client_dpi_scaling != nullptr) {
    enable_non_client_dpi_scaling(hwnd);
  }
  FreeLibrary(user32_module);
}

}  // namespace

// Manages the Win32Window's window class registration.
class WindowClassRegistrar {
 public:
  ~WindowClassRegistrar() = default;

  // Returns the singleton registrar instance.
  static WindowClassRegistrar* GetInstance() {
    if (!instance_) {
      instance_ = new WindowClassRegistrar();
    }
    return instance_;
  }

  // Returns the name of the window class, registering the class if it hasn't
  // previously been registered.
  const wchar_t* GetWindowClass();

  // Unregisters the window class. Should only be called if there are no
  // instances of the window.
  void UnregisterWindowClass();

 private:
  WindowClassRegistrar() = default;

  static WindowClassRegistrar* instance_;

  bool class_registered_ = false;
};

WindowClassRegistrar* WindowClassRegistrar::instance_ = nullptr;

const wchar_t* WindowClassRegistrar::GetWindowClass() {
  if (!class_registered_) {
    WNDCLASS window_class{};
    window_class.hCursor = LoadCursor(nullptr, IDC_ARROW);
    window_class.lpszClassName = kWindowClassName;
    window_class.style = CS_HREDRAW | CS_VREDRAW;
    window_class.cbClsExtra = 0;
    window_class.cbWndExtra = 0;
    window_class.hInstance = GetModuleHandle(nullptr);
    window_class.hIcon =
        LoadIcon(window_class.hInstance, MAKEINTRESOURCE(IDI_APP_ICON));
    window_class.hbrBackground = 0;
    window_class.lpszMenuName = nullptr;
    window_class.lpfnWndProc = Win32Window::WndProc;
    RegisterClass(&window_class);
    class_registered_ = true;
  }
  return kWindowClassName;
}

void WindowClassRegistrar::UnregisterWindowClass() {
  UnregisterClass(kWindowClassName, nullptr);
  class_registered_ = false;
}

Win32Window::Win32Window() {
  ++g_active_window_count;
}

Win32Window::~Win32Window() {
  --g_active_window_count;
  Destroy();
}

bool Win32Window::Create(const std::wstring& title,
                         const Point& origin,
                         const Size& size) {
  Destroy();
  default_corner_gap_ = -1;

  const wchar_t* window_class =
      WindowClassRegistrar::GetInstance()->GetWindowClass();

  const POINT target_point = {static_cast<LONG>(origin.x),
                              static_cast<LONG>(origin.y)};
  HMONITOR monitor = MonitorFromPoint(target_point, MONITOR_DEFAULTTONEAREST);
  UINT dpi = FlutterDesktopGetDpiForMonitor(monitor);
  double scale_factor = dpi / 96.0;

  HWND window = CreateWindow(
      window_class, title.c_str(), kWindowStyle,
      Scale(origin.x, scale_factor), Scale(origin.y, scale_factor),
      Scale(size.width, scale_factor), Scale(size.height, scale_factor),
      nullptr, nullptr, GetModuleHandle(nullptr), this);

  if (!window) {
    return false;
  }

  UpdateTheme(window);
  UpdateIcons(GetDpiForWindow(window));
  SetWindowPos(window, nullptr, 0, 0, 0, 0,
               SWP_FRAMECHANGED | SWP_NOMOVE | SWP_NOSIZE | SWP_NOZORDER |
                   SWP_NOACTIVATE);

  return OnCreate();
}

bool Win32Window::Show() {
#ifdef SYBL_VISUAL_UAT
  const bool was_visible = ShowWindow(window_handle_, SW_SHOWNOACTIVATE);
#else
  const bool was_visible = ShowWindow(window_handle_, SW_SHOWNORMAL);
#endif
  if (default_corner_gap_ >= 0 && IsWindowVisible(window_handle_)) {
    ApplyDefaultCornerPlacement();
    default_corner_gap_ = -1;
  }
  return was_visible;
}

void Win32Window::SetDefaultCornerGap(int logical_gap) {
  default_corner_gap_ = (std::max)(0, logical_gap);
  ApplyDefaultCornerPlacement();
}

void Win32Window::ApplyDefaultCornerPlacement() {
  RECT work{}, outer{};
  if (!window_handle_ ||
      !SystemParametersInfoW(SPI_GETWORKAREA, 0, &work, 0) ||
      !GetWindowRect(window_handle_, &outer)) return;
  const auto frame = sybl::window::VisibleFrameInsets(window_handle_, outer);
  const UINT dpi = GetDpiForWindow(window_handle_);
  const int gap = MulDiv(default_corner_gap_, dpi ? dpi : 96, 96);
  const auto bounds = sybl::window::ChooseDefaultBounds(
      {work.left, work.top, work.right, work.bottom},
      outer.right - outer.left, outer.bottom - outer.top, frame, gap);
  SetWindowPos(window_handle_, nullptr, bounds.x, bounds.y, bounds.width,
               bounds.height, SWP_NOZORDER | SWP_NOACTIVATE);
}

// static
LRESULT CALLBACK Win32Window::WndProc(HWND const window,
                                      UINT const message,
                                      WPARAM const wparam,
                                      LPARAM const lparam) noexcept {
  if (message == WM_NCCREATE) {
    auto window_struct = reinterpret_cast<CREATESTRUCT*>(lparam);
    SetWindowLongPtr(window, GWLP_USERDATA,
                     reinterpret_cast<LONG_PTR>(window_struct->lpCreateParams));

    auto that = static_cast<Win32Window*>(window_struct->lpCreateParams);
    EnableFullDpiSupportIfAvailable(window);
    that->window_handle_ = window;
  } else if (Win32Window* that = GetThisFromHandle(window)) {
    return that->MessageHandler(window, message, wparam, lparam);
  }

  return DefWindowProc(window, message, wparam, lparam);
}

LRESULT
Win32Window::MessageHandler(HWND hwnd,
                            UINT const message,
                            WPARAM const wparam,
                            LPARAM const lparam) noexcept {
  switch (message) {
    case kAppearanceMessage:
      return SetDisaccordBorder(hwnd, wparam != 0) ? TRUE : FALSE;
    case kWindowEdgeSpacingMessage:
      if ((wparam != 8 && wparam != 24) || (lparam != 0 && lparam != 1))
        return FALSE;
      return SetWindowEdgeSpacing(hwnd, static_cast<int>(wparam), lparam != 0)
          ? TRUE : FALSE;
    case kWindowPresentationStateMessage:
      if (presentation_timer_ && !IsIconic(hwnd) && !IsZoomed(hwnd))
        return (presentation_mode_ != 0 ? 1 : 2) | 4;
      return sybl::window::PresentationState(hwnd, presentation_mode_, window_edge_gap_);
    case kFinishWindowPresentationMessage:
      FinishPresentationAnimation();
      return 0;
    case kWindowPresentationMessage:
      return SetPresentation(hwnd, static_cast<int>(wparam),
          (lparam & 1) != 0, (lparam & 2) != 0) ? TRUE : FALSE;
    case kWindowPresentationFrameMessage:
      if (presentation_timer_ && wparam == presentation_generation_) {
        if (!IsWindowVisible(hwnd) || IsIconic(hwnd) || IsZoomed(hwnd)) {
          CancelPresentationAnimation(hwnd);
          return 0;
        }
        const double progress = PresentationElapsedMs() /
            sybl::window::kPresentationAnimationMs;
        const RECT bounds = sybl::window::InterpolateBounds(
            presentation_from_, presentation_target_, progress);
        if (progress >= 1) CancelPresentationAnimation(hwnd);
        if (!SetWindowPos(hwnd, nullptr, bounds.left, bounds.top,
            bounds.right - bounds.left, bounds.bottom - bounds.top,
            SWP_NOZORDER | SWP_NOACTIVATE)) CancelPresentationAnimation(hwnd);
        if (presentation_timer_ && !SchedulePresentationFrame())
          FinishPresentationAnimation();
        return 0;
      }
      return 0;
    case WM_SHOWWINDOW:
      if (!wparam) FinishPresentationAnimation();
      break;
    case WM_DISPLAYCHANGE:
      FinishPresentationAnimation();
      break;
    case WM_SETTINGCHANGE:
      if (wparam == SPI_SETWORKAREA) FinishPresentationAnimation();
      break;
    case WM_ENTERSIZEMOVE:
      CancelPresentationAnimation(hwnd);
      break;
    case WM_SYSCOMMAND:
      if ((wparam & 0xfff0) == SC_MINIMIZE && !IsWindowVisible(hwnd)) return 0;
      if ((wparam & 0xfff0) == SC_RESTORE && IsIconic(hwnd)) {
        RevealMinimized(hwnd);
        return 0;
      }
      FinishPresentationAnimation();
      break;
    case WM_GETMINMAXINFO: {
      auto* limits = reinterpret_cast<MINMAXINFO*>(lparam);
      const UINT window_dpi = GetDpiForWindow(hwnd);
      const UINT dpi = window_dpi == 0 ? USER_DEFAULT_SCREEN_DPI : window_dpi;
      const int resize_border =
          GetSystemMetricsForDpi(SM_CYFRAME, dpi) +
          GetSystemMetricsForDpi(SM_CXPADDEDBORDER, dpi);
      const LONG minimum_height = presentation_mode_ != 0
          ? MulDiv(120, dpi, 96) + resize_border
          : MinimumTrackHeight(dpi, resize_border);
      limits->ptMinTrackSize.x = sybl::window::MinimumTrackWidth(
          dpi, resize_border);
      if (limits->ptMinTrackSize.y < minimum_height) {
        limits->ptMinTrackSize.y = minimum_height;
      }
      return 0;
    }

    case WM_NCCALCSIZE:
      if (wparam == TRUE) {
        auto* params = reinterpret_cast<NCCALCSIZE_PARAMS*>(lparam);
        const LONG window_top = params->rgrc[0].top;
        DefWindowProc(hwnd, message, wparam, lparam);
        if (IsZoomed(hwnd)) {
          // A maximized window extends its resize frame beyond the monitor.
          // Keep the client below that off-screen edge.
          const UINT dpi = GetDpiForWindow(hwnd);
          params->rgrc[0].top =
              window_top + GetSystemMetricsForDpi(SM_CYFRAME, dpi) +
              GetSystemMetricsForDpi(SM_CXPADDEDBORDER, dpi);
        } else {
          // Let Flutter paint its title bar to the outer top edge. Hit testing
          // still reserves the top frame pixels for native resizing.
          params->rgrc[0].top = window_top;
        }
        return 0;
      }
      break;

    case WM_NCHITTEST: {
      if (IsZoomed(hwnd)) return HTCLIENT;
      RECT bounds{};
      GetWindowRect(hwnd, &bounds);
      const UINT dpi = GetDpiForWindow(hwnd);
      const LONG border =
          GetSystemMetricsForDpi(SM_CXFRAME, dpi) +
          GetSystemMetricsForDpi(SM_CXPADDEDBORDER, dpi);
      const POINT point{GET_X_LPARAM(lparam), GET_Y_LPARAM(lparam)};
      const bool left = point.x < bounds.left + border;
      const bool right = point.x >= bounds.right - border;
      const bool top = point.y < bounds.top + border;
      const bool bottom = point.y >= bounds.bottom - border;
      if (top && left) return HTTOPLEFT;
      if (top && right) return HTTOPRIGHT;
      if (bottom && left) return HTBOTTOMLEFT;
      if (bottom && right) return HTBOTTOMRIGHT;
      if (left) return HTLEFT;
      if (right) return HTRIGHT;
      if (top) return HTTOP;
      if (bottom) return HTBOTTOM;
      return HTCLIENT;
    }

    case WM_DESTROY:
      CancelPresentationAnimation(hwnd);
      window_handle_ = nullptr;
      Destroy();
      if (quit_on_close_) {
        PostQuitMessage(0);
      }
      return 0;

    case WM_DPICHANGED: {
      CancelPresentationAnimation(hwnd);
      UpdateIcons(LOWORD(wparam));
      RECT proposed = *reinterpret_cast<RECT*>(lparam);
      if (presentation_mode_ != 0) {
        MONITORINFO monitor{sizeof(MONITORINFO)};
        if (GetMonitorInfoW(MonitorFromRect(&proposed, MONITOR_DEFAULTTONEAREST), &monitor)) {
          const RECT area = monitor.rcWork;
          const LONG width = (std::min)(proposed.right - proposed.left, area.right - area.left);
          const LONG height = (std::min)(proposed.bottom - proposed.top, area.bottom - area.top);
          proposed.left = std::clamp(proposed.left, area.left, area.right - width);
          proposed.top = std::clamp(proposed.top, area.top, area.bottom - height);
          proposed.right = proposed.left + width;
          proposed.bottom = proposed.top + height;
        }
      }
      auto newRectSize = &proposed;
      LONG newWidth = newRectSize->right - newRectSize->left;
      LONG newHeight = newRectSize->bottom - newRectSize->top;

      SetWindowPos(hwnd, nullptr, newRectSize->left, newRectSize->top, newWidth,
                   newHeight, SWP_NOZORDER | SWP_NOACTIVATE);

      return 0;
    }
    case WM_SIZE: {
      RECT rect = GetClientArea();
      if (child_content_ != nullptr) {
        // Size and position the child window.
        MoveWindow(child_content_, rect.left, rect.top, rect.right - rect.left,
                   rect.bottom - rect.top, TRUE);
      }
      return 0;
    }

    case WM_ACTIVATE:
      if (child_content_ != nullptr) {
        SetFocus(child_content_);
      }
      return 0;

    case WM_DWMCOLORIZATIONCOLORCHANGED:
    case WM_THEMECHANGED:
      UpdateTheme(hwnd);
      return 0;
  }

  return DefWindowProc(window_handle_, message, wparam, lparam);
}

bool Win32Window::RevealMinimized(HWND window) noexcept {
  ShowWindow(window, SW_RESTORE);
  return true;
}

void Win32Window::CancelPresentationAnimation(HWND) noexcept {
  if (presentation_wait_) {
    SetThreadpoolWait(presentation_wait_, nullptr, nullptr);
    // The callback only posts a message, so it never waits for this thread.
    WaitForThreadpoolWaitCallbacks(presentation_wait_, TRUE);
    CloseThreadpoolWait(presentation_wait_);
    presentation_wait_ = nullptr;
  }
  if (presentation_timer_) {
    CancelWaitableTimer(presentation_timer_);
    CloseHandle(presentation_timer_);
    presentation_timer_ = nullptr;
  }
  // Already-posted frames must not drive a subsequent/reversed animation.
  ++presentation_generation_;
}

void CALLBACK Win32Window::PresentationFrameReady(
    PTP_CALLBACK_INSTANCE, void* context, PTP_WAIT, TP_WAIT_RESULT) noexcept {
  auto* window = static_cast<Win32Window*>(context);
  PostMessageW(window->window_handle_, kWindowPresentationFrameMessage,
      window->presentation_generation_, 0);
}

double Win32Window::PresentationElapsedMs() const noexcept {
  LARGE_INTEGER now{};
  QueryPerformanceCounter(&now);
  return 1000.0 * static_cast<double>(now.QuadPart - presentation_started_.QuadPart) /
      static_cast<double>(presentation_frequency_.QuadPart);
}

bool Win32Window::SchedulePresentationFrame() noexcept {
  LARGE_INTEGER due{};
  due.QuadPart = -sybl::window::PresentationFrameDelay(
      PresentationElapsedMs(), presentation_refresh_hz_);
  if (!SetWaitableTimer(presentation_timer_, &due, 0, nullptr, nullptr, FALSE))
    return false;
  // One outstanding frame at a time; a busy platform thread cannot accumulate
  // a queue of obsolete geometry updates.
  SetThreadpoolWait(presentation_wait_, presentation_timer_, nullptr);
  return true;
}

void Win32Window::FinishPresentationAnimation() noexcept {
  if (!presentation_timer_) return;
  RECT target = presentation_target_;
  CancelPresentationAnimation(window_handle_);
  MONITORINFO monitor{sizeof(MONITORINFO)};
  if (GetMonitorInfoW(MonitorFromRect(&target, MONITOR_DEFAULTTONEAREST), &monitor)) {
    const RECT area = monitor.rcWork;
    const LONG width = (std::min)(target.right - target.left, area.right - area.left);
    const LONG height = (std::min)(target.bottom - target.top, area.bottom - area.top);
    target.left = std::clamp(target.left, area.left, area.right - width);
    target.top = std::clamp(target.top, area.top, area.bottom - height);
    target.right = target.left + width;
    target.bottom = target.top + height;
  }
  SetWindowPos(window_handle_, nullptr, target.left, target.top,
      target.right - target.left, target.bottom - target.top,
      SWP_NOZORDER | SWP_NOACTIVATE);
}

bool Win32Window::MovePresentation(HWND hwnd, const RECT& target, bool animate) noexcept {
  presentation_target_ = target;
  if (animate && GetWindowRect(hwnd, &presentation_from_) &&
      !EqualRect(&presentation_from_, &target)) {
    MONITORINFOEXW monitor{};
    monitor.cbSize = sizeof(monitor);
    DEVMODEW display{};
    display.dmSize = sizeof(display);
    presentation_refresh_hz_ = 60;
    if (GetMonitorInfoW(MonitorFromWindow(hwnd, MONITOR_DEFAULTTONEAREST), &monitor) &&
        EnumDisplaySettingsW(monitor.szDevice, ENUM_CURRENT_SETTINGS, &display))
      presentation_refresh_hz_ = display.dmDisplayFrequency;
    QueryPerformanceFrequency(&presentation_frequency_);
    QueryPerformanceCounter(&presentation_started_);
    presentation_timer_ = CreateWaitableTimerExW(nullptr, nullptr,
        CREATE_WAITABLE_TIMER_HIGH_RESOLUTION, TIMER_ALL_ACCESS);
    if (!presentation_timer_)
      presentation_timer_ = CreateWaitableTimerW(nullptr, FALSE, nullptr);
    if (presentation_timer_)
      presentation_wait_ = CreateThreadpoolWait(PresentationFrameReady, this, nullptr);
    if (presentation_wait_ && SchedulePresentationFrame()) return true;
    CancelPresentationAnimation(hwnd);
  }
  return SetWindowPos(hwnd, nullptr, target.left, target.top,
      target.right - target.left, target.bottom - target.top,
      SWP_NOZORDER | SWP_NOACTIVATE) != FALSE;
}

bool Win32Window::SetWindowEdgeSpacing(HWND hwnd, int logical_gap,
                                     bool reposition) noexcept {
  window_edge_gap_ = logical_gap;
  if (!reposition) return true;
  // Explicit preference changes retire the old compact anchor, including when
  // hidden. A bootstrap preference read preserves restored/dragged placement.
  compact_bounds_ = {};
  if (!IsWindowVisible(hwnd) || IsIconic(hwnd) || IsZoomed(hwnd)) return true;
  FinishPresentationAnimation();
  MONITORINFO monitor{sizeof(MONITORINFO)};
  RECT current{};
  if (!GetMonitorInfoW(MonitorFromWindow(hwnd, MONITOR_DEFAULTTONEAREST), &monitor) ||
      !GetWindowRect(hwnd, &current)) return false;
  const RECT area = monitor.rcWork;
  const UINT dpi = GetDpiForWindow(hwnd);
  const auto bounds = sybl::window::ChooseDefaultBounds(
      {area.left, area.top, area.right, area.bottom},
      current.right - current.left, current.bottom - current.top,
      sybl::window::VisibleFrameInsets(hwnd, current),
      MulDiv(logical_gap, dpi ? dpi : 96, 96));
  if (!SetWindowPos(hwnd, nullptr, bounds.x, bounds.y, bounds.width, bounds.height,
      SWP_NOZORDER | SWP_NOACTIVATE)) return false;
  // A visible compact window now has a valid anchor at the new spacing. Keep
  // its user-resized dimensions through the next expand/compact cycle.
  if (presentation_mode_ == 1) GetWindowRect(hwnd, &compact_bounds_);
  return true;
}

bool Win32Window::SetPresentation(HWND hwnd, int mode, bool animate,
                                  bool reset_position) noexcept {
  if (mode < 0 || mode > 3) return false;
  // A hidden window is left exactly as it is: the command only records the
  // latest requested mode, which the covered reveal applies once the window is
  // visible again.
  if (!IsWindowVisible(hwnd)) {
    deferred_presentation_mode_ = mode;
    deferred_reset_position_ = reset_position;
    return true;
  }
  const bool was_animating = presentation_timer_ != 0;
  const bool was_deferred = deferred_presentation_mode_ >= 0;
  deferred_presentation_mode_ = -1;
  deferred_reset_position_ = false;
  if (mode != 0 && mode == presentation_mode_ && !was_deferred) return true;
  CancelPresentationAnimation(hwnd);
  animate = animate && !IsZoomed(hwnd) && !IsIconic(hwnd) && !was_deferred;
  // A minimized visible window is restored by the owner's reveal routine
  // before it is repositioned.
  if (IsIconic(hwnd) && !RevealMinimized(hwnd)) return false;
  if (mode == 0) {
    const HMONITOR target_monitor = MonitorFromWindow(hwnd, MONITOR_DEFAULTTONEAREST);
    MONITORINFO monitor{sizeof(MONITORINFO)};
    if (!GetMonitorInfoW(target_monitor, &monitor))
      return false;
    if (presentation_mode_ == 1 && compact_bounds_.right > compact_bounds_.left &&
        !was_animating && !IsZoomed(hwnd) && !IsIconic(hwnd))
      GetWindowRect(hwnd, &compact_bounds_);
    RECT current{};
    if (presentation_mode_ != 0 && animate) {
      current = normal_placement_.rcNormalPosition;
      MONITORINFO previous{sizeof(MONITORINFO)};
      if (GetMonitorInfoW(MonitorFromRect(&current, MONITOR_DEFAULTTONEAREST), &previous))
        OffsetRect(&current, previous.rcWork.left - previous.rcMonitor.left,
            previous.rcWork.top - previous.rcMonitor.top);
    } else {
      if (presentation_mode_ != 0) {
        auto restored = normal_placement_;
        restored.showCmd = SW_SHOWNORMAL;
        if (!SetWindowPlacement(hwnd, &restored)) return false;
      } else if (IsZoomed(hwnd)) {
        ShowWindow(hwnd, SW_RESTORE);
      }
      if (!GetWindowRect(hwnd, &current)) return false;
    }
    const RECT area = monitor.rcWork;
    const UINT dpi = FlutterDesktopGetDpiForMonitor(target_monitor);
    SIZE size = sybl::window::DefaultWindowSize(dpi, area);
    LONG x = std::clamp(current.left, area.left, area.right - size.cx);
    LONG y = std::clamp(current.top, area.top, area.bottom - size.cy);
    if (reset_position) {
      RECT outer{};
      if (!GetWindowRect(hwnd, &outer)) return false;
      const auto bounds = sybl::window::ChooseDefaultBounds(
          {area.left, area.top, area.right, area.bottom}, size.cx, size.cy,
          sybl::window::VisibleFrameInsets(hwnd, outer),
          MulDiv(window_edge_gap_, dpi ? dpi : 96, 96));
      x = bounds.x;
      y = bounds.y;
      size = {bounds.width, bounds.height};
    }
    presentation_mode_ = 0;
    RemovePropW(hwnd, kCompactWindowProperty);
    normal_placement_.showCmd = SW_SHOWNORMAL;
    normal_placement_.rcNormalPosition = {x, y, x + size.cx, y + size.cy};
    OffsetRect(&normal_placement_.rcNormalPosition,
        monitor.rcMonitor.left - area.left, monitor.rcMonitor.top - area.top);
    return MovePresentation(hwnd, {x, y, x + size.cx, y + size.cy}, animate);
  }
  if (presentation_mode_ == 0 && !was_animating) {
    if (!GetWindowPlacement(hwnd, &normal_placement_)) return false;
  } else if (presentation_mode_ == 1 && compact_bounds_.right > compact_bounds_.left &&
      !was_animating && !IsZoomed(hwnd) && !IsIconic(hwnd)) {
    GetWindowRect(hwnd, &compact_bounds_);
  }
  // Restore compact placement against its own monitor, including its DPI.
  const bool remembered = mode == 1 && compact_bounds_.right > compact_bounds_.left;
  const HMONITOR target_monitor = remembered
      ? MonitorFromRect(&compact_bounds_, MONITOR_DEFAULTTONEAREST)
      : MonitorFromWindow(hwnd, MONITOR_DEFAULTTONEAREST);
  MONITORINFO monitor{sizeof(MONITORINFO)};
  if (!GetMonitorInfoW(target_monitor, &monitor))
    return false;
  const UINT dpi = FlutterDesktopGetDpiForMonitor(target_monitor);
  const auto scale = [dpi](int value) { return MulDiv(value, dpi ? dpi : 96, 96); };
  const int border = GetSystemMetricsForDpi(SM_CXFRAME, dpi) +
      GetSystemMetricsForDpi(SM_CXPADDEDBORDER, dpi);
  const RECT area = monitor.rcWork;
  int width = scale(mode == 1 ? 320 : 300) + 2 * border;
  int height = scale(mode == 1 ? 360 : mode == 2 ? 132 : 156) + border;
  // DWM's maximized frame has no invisible resize insets. Measure the restored
  // frame before choosing the compact window's visible corner gap.
  if (IsZoomed(hwnd)) ShowWindow(hwnd, SW_RESTORE);
  RECT current{};
  if (!GetWindowRect(hwnd, &current)) return false;
  int x = current.left;
  int y = current.top;
  if (remembered) {
    x = compact_bounds_.left;
    y = compact_bounds_.top;
    width = compact_bounds_.right - compact_bounds_.left;
    height = compact_bounds_.bottom - compact_bounds_.top;
    width = (std::min)(width, static_cast<int>(area.right - area.left));
    height = (std::min)(height, static_cast<int>(area.bottom - area.top));
    x = std::clamp(x, static_cast<int>(area.left), static_cast<int>(area.right) - width);
    y = std::clamp(y, static_cast<int>(area.top), static_cast<int>(area.bottom) - height);
  } else {
    const auto bounds = sybl::window::ChooseDefaultBounds(
        {area.left, area.top, area.right, area.bottom}, width, height,
        sybl::window::VisibleFrameInsets(hwnd, current), scale(window_edge_gap_));
    x = bounds.x;
    y = bounds.y;
    width = bounds.width;
    height = bounds.height;
  }
  presentation_mode_ = mode;
  SetPropW(hwnd, kCompactWindowProperty, reinterpret_cast<HANDLE>(1));
  compact_bounds_ = mode == 1 ? RECT{x, y, x + width, y + height} : compact_bounds_;
  return MovePresentation(hwnd, {x, y, x + width, y + height}, animate);
}


bool Win32Window::ApplyDeferredPresentation() noexcept {
  const HWND hwnd = window_handle_;
  if (deferred_presentation_mode_ < 0 || !hwnd || !IsWindowVisible(hwnd))
    return true;
  const int mode = deferred_presentation_mode_;
  return SetPresentation(hwnd, mode, false, deferred_reset_position_);
}

void Win32Window::Destroy() {
  OnDestroy();

  if (window_handle_) {
    DestroyWindow(window_handle_);
    window_handle_ = nullptr;
  }
  if (small_icon_) {
    DestroyIcon(small_icon_);
    small_icon_ = nullptr;
  }
  if (large_icon_) {
    DestroyIcon(large_icon_);
    large_icon_ = nullptr;
  }
  if (g_active_window_count == 0) {
    WindowClassRegistrar::GetInstance()->UnregisterWindowClass();
  }
}

Win32Window* Win32Window::GetThisFromHandle(HWND const window) noexcept {
  return reinterpret_cast<Win32Window*>(
      GetWindowLongPtr(window, GWLP_USERDATA));
}

void Win32Window::SetChildContent(HWND content) {
  child_content_ = content;
  SetParent(content, window_handle_);
  SetWindowSubclass(content, ResizeFrameSubclass, 0, 0);
  RECT frame = GetClientArea();

  MoveWindow(content, frame.left, frame.top, frame.right - frame.left,
             frame.bottom - frame.top, true);

#ifndef SYBL_VISUAL_UAT
  SetFocus(child_content_);
#endif
}

RECT Win32Window::GetClientArea() {
  RECT frame;
  GetClientRect(window_handle_, &frame);
  return frame;
}

HWND Win32Window::GetHandle() {
  return window_handle_;
}

void Win32Window::SetQuitOnClose(bool quit_on_close) {
  quit_on_close_ = quit_on_close;
}

bool Win32Window::OnCreate() {
  // No-op; provided for subclasses.
  return true;
}

void Win32Window::OnDestroy() {
  // No-op; provided for subclasses.
}

void Win32Window::UpdateIcons(UINT dpi) noexcept {
  if (!dpi) dpi = USER_DEFAULT_SCREEN_DPI;
  const auto replace = [&](WPARAM kind, int width_metric, int height_metric,
                           HICON& current) {
    const auto icon = static_cast<HICON>(LoadImageW(
        GetModuleHandleW(nullptr), MAKEINTRESOURCEW(IDI_APP_ICON), IMAGE_ICON,
        GetSystemMetricsForDpi(width_metric, dpi),
        GetSystemMetricsForDpi(height_metric, dpi), 0));
    if (!icon) return;
    SendMessageW(window_handle_, WM_SETICON, kind, reinterpret_cast<LPARAM>(icon));
    if (current) DestroyIcon(current);
    current = icon;
  };
  replace(ICON_SMALL, SM_CXSMICON, SM_CYSMICON, small_icon_);
  replace(ICON_BIG, SM_CXICON, SM_CYICON, large_icon_);
}

bool Win32Window::SetDisaccordBorder(HWND window, bool enabled) noexcept {
  if (!window || !IsWindow(window)) return false;
  auto* owner = GetThisFromHandle(window);
  if (!owner) return false;
  owner->disaccord_border_ = enabled;
  owner->UpdateTheme(window);
  return true;
}

void Win32Window::UpdateTheme(HWND const window) {
  // Windows 11 rounds eligible top-level windows automatically, but asking
  // explicitly also covers our captionless (still natively resizable) frame.
  // Older Windows versions simply reject these attributes.
  const DWORD corner_preference = 2;  // DWMWCP_ROUND
  DwmSetWindowAttribute(window, DWMWA_WINDOW_CORNER_PREFERENCE,
                        &corner_preference, sizeof(corner_preference));
  // Only Disaccord has an outer edge. Start borderless until Dart loads the
  // saved preset, and retain that choice when the OS sends a theme refresh.
  const COLORREF border_color = disaccord_border_
      ? RGB(64, 64, 69) : DWMWA_COLOR_NONE;
  DwmSetWindowAttribute(window, DWMWA_BORDER_COLOR, &border_color,
                        sizeof(border_color));

  DWORD light_mode;
  DWORD light_mode_size = sizeof(light_mode);
  LSTATUS result = RegGetValue(HKEY_CURRENT_USER, kGetPreferredBrightnessRegKey,
                               kGetPreferredBrightnessRegValue,
                               RRF_RT_REG_DWORD, nullptr, &light_mode,
                               &light_mode_size);

  if (result == ERROR_SUCCESS) {
    BOOL enable_dark_mode = light_mode == 0;
    DwmSetWindowAttribute(window, DWMWA_USE_IMMERSIVE_DARK_MODE,
                          &enable_dark_mode, sizeof(enable_dark_mode));
  }
}
